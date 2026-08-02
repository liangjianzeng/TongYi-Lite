import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import '../models/model_info.dart';
import 'model_manager.dart';
import 'model_storage_service.dart';

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  // Extended timeouts for large model downloads (up to 2GB)
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(minutes: 3),
    receiveTimeout: const Duration(hours: 2), // Very long timeout for large files
    sendTimeout: const Duration(minutes: 5),
  ));

  static const int maxConcurrentDownloads = 1; // Only one at a time to avoid CDN issues

  final Map<String, _ActiveDownload> _activeDownloads = {};
  final Map<String, DateTime> _lastProgressTime = {};

  List<DownloadTask> get activeTasks =>
      _activeDownloads.values.map((d) => d.task).toList();

  Future<void> download(
    ModelConfig model, {
    required void Function(DownloadTask) onProgress,
    Duration progressInterval = const Duration(milliseconds: 500),
    DownloadTask? existingTask, // Optional task to reuse (e.g., from provider's initialTask)
  }) async {
    if (_activeDownloads.length >= maxConcurrentDownloads) {
      throw DownloadException('Only one download at a time.');
    }

    final task = existingTask ?? DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: 0, // Don't preset — let Dio's Content-Length or catalog size set it.
      startTime: DateTime.now(),
    );

    _activeDownloads[model.id] = _ActiveDownload(task: task);
    onProgress(task);

    CancelToken? cancelToken;
    try {
      // Step 1: Resolve URL and verify server supports Range requests
      final hasPartialTmp = await _hasPartialTmp(model.id);
      _UrlInfo? urlInfo;

      if (!hasPartialTmp) {
        urlInfo = await _resolveUrl(model.mirrors);
        if (urlInfo == null) {
          throw DownloadException('All mirrors unreachable.');
        }
      } else {
        final firstMirror = model.mirrors.first;
        urlInfo = _UrlInfo(url: firstMirror.url, supportsRange: true);
        debugPrint('[DownloadService] Resume detected for ${model.id}, skipping HEAD probe');
      }

      final dir = await _getModelsDir();
      await dir.create(recursive: true);
      final tempFile = File(p.join(dir.path, model.id + '.gguf.tmp'));
      final finalFile = File(p.join(dir.path, model.id + '.gguf'));

      // Step 2: Decide resume point from any existing partial .tmp
      int downloadedSoFar = 0;
      final supportsRange = urlInfo.supportsRange;

      if (await tempFile.exists()) {
        final len = await tempFile.length();
        if (len >= model.sizeBytes && model.sizeBytes > 0) {
          // Already complete — just promote and finish
          task.totalBytes = model.sizeBytes;
          await tempFile.rename(finalFile.path);
          task.state = DownloadState.completed;
          task.downloadedBytes = model.sizeBytes;
          task.endTime = DateTime.now();
          onProgress(task);
          _activeDownloads.remove(model.id);
          return;
        } else if (supportsRange && len > 0) {
          // Mirror supports Range → resume from the byte we already have
          downloadedSoFar = len;
          task.downloadedBytes = downloadedSoFar;
          task.totalBytes = model.sizeBytes; // needed for progress display during resume
          debugPrint('[DownloadService] Resuming from ${_formatBytes(downloadedSoFar)}');
          onProgress(task);
        } else {
          // No Range support or corrupt partial → restart fresh
          debugPrint('[DownloadService] No resume possible, restarting fresh');
          await tempFile.delete();
          downloadedSoFar = 0;
        }
      }

      // Step 3: Download. Use ranged-append when the mirror supports Range + we have a
      // partial file (true 断点续传); otherwise a plain single-connection download.
      cancelToken = CancelToken();
      _activeDownloads[model.id] = _ActiveDownload(task: task, cancelToken: cancelToken);

      if (supportsRange && downloadedSoFar > 0) {
        await _downloadRange(
          urlInfo.url,
          tempFile,
          downloadedSoFar,
          model.sizeBytes,
          task,
          cancelToken,
          onProgress,
          progressInterval,
        );
      } else {
        // Use catalog size as fallback for progress display.
        if (task.totalBytes == 0) task.totalBytes = model.sizeBytes;

        // Explicit stream-based download with reliable byte-counting progress.
        // Dio's onReceiveProgress is unreliable on Android; we track bytes ourselves.
        final response = await _dio.get<ResponseBody>(
          urlInfo.url,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(hours: 2),
          ),
          cancelToken: cancelToken,
        );

        final body = response.data;
        if (body == null) throw DownloadException('Empty response body.');

        // Get Content-Length from headers for total size.
        final headerTotalStr = response.headers.value('content-length');
        if (headerTotalStr != null) {
          final headerTotal = int.tryParse(headerTotalStr);
          if (headerTotal != null && headerTotal > 0 && task.totalBytes == 0) {
            task.totalBytes = headerTotal;
            debugPrint('[DownloadService] Using Content-Length from headers: $headerTotal bytes');
          }
        }

        final raf = tempFile.openSync(mode: FileMode.writeOnlyAppend);
        int received = downloadedSoFar;
        DateTime? _lastProgressTime;

        try {
          await for (final chunk in body.stream) {
            if (cancelToken?.isCancelled == true) break;
            await raf.writeFrom(chunk);
            received += chunk.length;
            task.downloadedBytes = received;

            // Emit progress at least every 500ms or on each chunk if chunks are small.
            final now = DateTime.now();
            if (_lastProgressTime == null ||
                now.difference(_lastProgressTime!) >= progressInterval) {
              _lastProgressTime = now;
              onProgress(task);
            }
          }
        } finally {
          await raf.close();
        }

        // Final progress emit to ensure completion state is sent.
        onProgress(task);
      }

      // Step 4: Verify download produced data — trust what the CDN actually served.
      final actualSize = await tempFile.length();
      if (actualSize == 0) {
        throw DownloadException('Download produced empty file');
      }

      // Step 5: Promote .tmp to final file
      await tempFile.rename(finalFile.path);
      task.state = DownloadState.completed;
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);
      onProgress(task);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        // Paused/cancelled — keep .tmp so the next run can resume
        return;
      }
      task.state = DownloadState.failed;
      task.errorMessage = _cleanErrorMessage(e.toString());
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);
      onProgress(task);

      // Remove corrupt .tmp so a retry starts clean
      try {
        final dir = await _getModelsDir();
        final tmp = File(p.join(dir.path, model.id + '.gguf.tmp'));
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    } finally {
      _activeDownloads.remove(model.id);
    }
  }

  /// Download a byte range [start, ∞) and append to [file]. Correctly implements
  /// resume over mirrors that return 206 (e.g. hf-mirror.com / HuggingFace CDN).
  Future<void> _downloadRange(
    String url,
    File file,
    int start,
    int total,
    DownloadTask task,
    CancelToken cancelToken,
    void Function(DownloadTask) onProgress,
    Duration progressInterval,
  ) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=$start-'},
        receiveTimeout: const Duration(hours: 2),
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body == null) throw DownloadException('Empty response body on resume.');

    final raf = file.openSync(mode: FileMode.append);
    try {
      int received = start;
      await for (final chunk in body.stream) {
        await raf.writeFrom(chunk);
        received += chunk.length;
        task.downloadedBytes = received;
        if (task.totalBytes == 0) task.totalBytes = total;
        _emitProgress(task, progressInterval, onProgress);
      }
    } finally {
      await raf.close();
    }
  }

  void _emitProgress(
    DownloadTask task,
    Duration interval,
    void Function(DownloadTask) onProgress,
  ) {
    final now = DateTime.now();
    final last = _lastProgressTime[task.modelId];
    if (last == null || now.difference(last) >= interval) {
      _lastProgressTime[task.modelId] = now;
      onProgress(task);
    }
  }

  Future<void> pause(String modelId) async {
    final active = _activeDownloads[modelId];
    if (active != null && active.task.state == DownloadState.downloading) {
      active.cancelToken?.cancel('Paused by user');
      active.task.state = DownloadState.paused;
      // Keep .tmp file for resume on next retry
    }
  }

  Future<void> resume(String modelId, {required void Function(DownloadTask) onProgress}) async {
    final model = ModelManager().getModel(modelId);
    if (model == null) throw DownloadException('Model not found: $modelId');

    // Resume: create a fresh task with state=downloading. The .tmp file on disk
    // provides the true resume data — we don't need to preserve progress in memory.
    final task = DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.sizeBytes,
      startTime: DateTime.now(),
    );

    await _doDownload(model, onProgress: (t) {
      // For resume, update the caller's task with progress.
      if (t.downloadedBytes > 0) {
        task.downloadedBytes = t.downloadedBytes;
        task.totalBytes = t.totalBytes;
        task.state = t.state;
      }
      onProgress(t);
    }, isNewTask: false, existingTask: task);
  }

  /// Internal download logic shared by [download] and [resume].
  Future<void> _doDownload(
    ModelConfig model, {
    required void Function(DownloadTask) onProgress,
    Duration progressInterval = const Duration(milliseconds: 500),
    bool isNewTask = true,
    DownloadTask? existingTask,
  }) async {
    if (_activeDownloads.length >= maxConcurrentDownloads) {
      throw DownloadException('Only one download at a time.');
    }

    final task = isNewTask
        ? (existingTask ?? DownloadTask(
            modelId: model.id,
            state: DownloadState.downloading,
            totalBytes: model.sizeBytes,
            startTime: DateTime.now(),
          ))
        : existingTask!; // For resume, caller must provide the task.

    _activeDownloads[model.id] = _ActiveDownload(task: task);
    if (isNewTask) onProgress(task);

    CancelToken? cancelToken;
    try {
      // Step 1: Resolve URL and verify server supports Range requests
      final hasPartialTmp = await _hasPartialTmp(model.id);
      _UrlInfo? urlInfo;

      if (!hasPartialTmp) {
        urlInfo = await _resolveUrl(model.mirrors);
        if (urlInfo == null) {
          throw DownloadException('All mirrors unreachable.');
        }
      } else {
        final firstMirror = model.mirrors.first;
        urlInfo = _UrlInfo(url: firstMirror.url, supportsRange: true);
        debugPrint('[DownloadService] Resume detected for ${model.id}, skipping HEAD probe');
      }

      final dir = await _getModelsDir();
      await dir.create(recursive: true);
      final tempFile = File(p.join(dir.path, model.id + '.gguf.tmp'));
      final finalFile = File(p.join(dir.path, model.id + '.gguf'));

      // Step 2: Decide resume point from any existing partial .tmp
      int downloadedSoFar = 0;
      final supportsRange = urlInfo.supportsRange;

      if (await tempFile.exists()) {
        final len = await tempFile.length();
        if (len >= model.sizeBytes && model.sizeBytes > 0) {
          // Already complete — just promote and finish
          await tempFile.rename(finalFile.path);
          task.state = DownloadState.completed;
          task.downloadedBytes = model.sizeBytes;
          task.endTime = DateTime.now();
          onProgress(task);
          _activeDownloads.remove(model.id);
          return;
        } else if (supportsRange && len > 0) {
          downloadedSoFar = len;
          task.downloadedBytes = downloadedSoFar;
          debugPrint('[DownloadService] Resuming from ${_formatBytes(downloadedSoFar)}');
          onProgress(task);
        } else {
          debugPrint('[DownloadService] No resume possible, restarting fresh');
          await tempFile.delete();
          downloadedSoFar = 0;
        }
      }

      // Step 3: Download. Use ranged-append when Range + partial file exist;
      // otherwise a plain single-connection download.
      cancelToken = CancelToken();
      _activeDownloads[model.id] = _ActiveDownload(task: task, cancelToken: cancelToken);

      if (supportsRange && downloadedSoFar > 0) {
        await _downloadRange(
          urlInfo.url, tempFile, downloadedSoFar, model.sizeBytes,
          task, cancelToken, onProgress, progressInterval,
        );
      } else {
        // Explicit stream-based download with reliable byte-counting progress.
        final response = await _dio.get<ResponseBody>(
          urlInfo.url,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(hours: 2),
          ),
          cancelToken: cancelToken,
        );

        final body = response.data;
        if (body == null) throw DownloadException('Empty response body.');

        final headerTotalStr = response.headers.value('content-length');
        if (headerTotalStr != null) {
          final headerTotal = int.tryParse(headerTotalStr);
          if (headerTotal != null && headerTotal > 0 && task.totalBytes == 0) {
            task.totalBytes = headerTotal;
          }
        }

        final raf = tempFile.openSync(mode: FileMode.writeOnlyAppend);
        int received = downloadedSoFar;
        DateTime? _lastProgressTime;

        try {
          await for (final chunk in body.stream) {
            if (cancelToken?.isCancelled == true) break;
            await raf.writeFrom(chunk);
            received += chunk.length;
            task.downloadedBytes = received;

            final now = DateTime.now();
            if (_lastProgressTime == null ||
                now.difference(_lastProgressTime!) >= progressInterval) {
              _lastProgressTime = now;
              onProgress(task);
            }
          }
        } finally {
          await raf.close();
        }
        onProgress(task);
      }

      // Step 4: Verify download produced data — trust what the CDN actually served.
      final actualSize = await tempFile.length();
      if (actualSize == 0) {
        throw DownloadException('Download produced empty file');
      }

      // Step 5: Promote .tmp to final file
      await tempFile.rename(finalFile.path);
      task.state = DownloadState.completed;
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);
      onProgress(task);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return; // Paused/cancelled — keep .tmp for resume.
      }
      task.state = DownloadState.failed;
      task.errorMessage = _cleanErrorMessage(e.toString());
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);
      onProgress(task);

      try {
        final dir = await _getModelsDir();
        final tmp = File(p.join(dir.path, model.id + '.gguf.tmp'));
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    } finally {
      _activeDownloads.remove(model.id);
    }
  }

  /// Check if a partial .tmp file exists for the given model.
  Future<bool> _hasPartialTmp(String modelId) async {
    try {
      final dir = await _getModelsDir();
      final tmpFile = File(p.join(dir.path, modelId + '.gguf.tmp'));
      return await tmpFile.exists() && (await tmpFile.length()) > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> cancel(String modelId) async {
    final active = _activeDownloads[modelId];
    if (active != null) {
      try { active.cancelToken?.cancel('Cancelled by user'); } catch (_) {}
      active.task.state = DownloadState.idle;
      _activeDownloads.remove(modelId);
    }

    // Delete ALL files on cancel — no resume possible after explicit cancel
    final dir = await _getModelsDir();
    for (final suffix in ['.gguf.tmp', '.gguf']) {
      final file = File(p.join(dir.path, modelId + suffix));
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
  }

  Future<void> deleteModel(String modelId) async {
    final dir = await _getModelsDir();
    final file = File(p.join(dir.path, modelId + '.gguf'));
    if (await file.exists()) { await file.delete(); }
    final tmpFile = File(p.join(dir.path, modelId + '.gguf.tmp'));
    if (await tmpFile.exists()) { await tmpFile.delete(); }
  }

  /// Resolve URL and check if server supports Range requests.
  Future<_UrlInfo?> _resolveUrl(List<MirrorEntry> mirrors) async {
    for (final mirror in mirrors) {
      debugPrint('[DownloadService] Checking mirror: ${mirror.source}');

      try {
        // Try HEAD first to check connectivity and support
        final response = await _dio.head(
          mirror.url,
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );

        if (response.statusCode == 200 || response.statusCode == 206) {
          // Check if server supports Range requests via Accept-Ranges header
          final acceptRanges = response.headers.value('accept-ranges');
          bool supportsRange = acceptRanges?.toLowerCase() == 'bytes';
          debugPrint('[DownloadService] Mirror ${mirror.source} OK (HEAD -> ${response.statusCode}, Range: $supportsRange)');

          return _UrlInfo(url: mirror.url, supportsRange: supportsRange);
        } else {
          debugPrint('[DownloadService] Mirror ${mirror.source} returned ${response.statusCode}, trying GET...');

          // HEAD not supported, try GET to verify the file exists
          final getResponse = await _dio.get(
            mirror.url,
            options: Options(
              receiveTimeout: const Duration(seconds: 10),
              responseType: ResponseType.bytes,
            ),
          );
          if (getResponse.statusCode == 200 || getResponse.statusCode == 206) {
            final acceptRanges = getResponse.headers.value('accept-ranges');
            bool supportsRange = acceptRanges?.toLowerCase() == 'bytes';
            debugPrint('[DownloadService] Mirror ${mirror.source} OK (GET -> ${getResponse.statusCode}, Range: $supportsRange)');

            return _UrlInfo(url: mirror.url, supportsRange: supportsRange);
          } else {
            debugPrint('[DownloadService] Mirror ${mirror.source} GET failed: ${getResponse.statusCode}');
          }
        }
      } catch (e) {
        debugPrint('[DownloadService] Mirror ${mirror.source} error: $e');

        // If HEAD fails, try GET as fallback
        try {
          final getResponse = await _dio.get(
            mirror.url,
            options: Options(
              receiveTimeout: const Duration(seconds: 10),
              responseType: ResponseType.bytes,
            ),
          );
          if (getResponse.statusCode == 200 || getResponse.statusCode == 206) {
            final acceptRanges = getResponse.headers.value('accept-ranges');
            bool supportsRange = acceptRanges?.toLowerCase() == 'bytes';
            debugPrint('[DownloadService] Mirror ${mirror.source} OK (GET fallback -> ${getResponse.statusCode}, Range: $supportsRange)');

            return _UrlInfo(url: mirror.url, supportsRange: supportsRange);
          } else {
            debugPrint('[DownloadService] Mirror ${mirror.source} GET failed: ${getResponse.statusCode}');
          }
        } catch (getE) {
          debugPrint('[DownloadService] Mirror ${mirror.source} GET error: $getE');
        }
      }
    }

    return null; // All mirrors unreachable
  }

  Future<Directory> _getModelsDir() async {
    final storage = ModelStorageService();
    return await storage.getModelsRootDir();
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _cleanErrorMessage(String error) {
    // Clean up Dio/HTTP exception messages for display
    if (error.contains('Connection closed while receiving data')) {
      return '连接断开，请重试（CDN不支持断点续传）';
    }
    if (error.contains('timeout')) {
      return '下载超时，请检查网络连接后重试';
    }
    if (error.length > 200) {
      // Truncate very long error messages
      final parts = error.split(':');
      if (parts.length >= 3) {
        return '${parts[0]}: ${parts[1]}: ... (${parts.last})';
      }
    }
    return error;
  }
}

class _UrlInfo {
  final String url;
  final bool supportsRange;

  const _UrlInfo({required this.url, required this.supportsRange});
}

class _ActiveDownload {
  final DownloadTask task;
  final CancelToken? cancelToken;

  _ActiveDownload({required this.task, this.cancelToken});
}

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => 'DownloadError: $message';
}