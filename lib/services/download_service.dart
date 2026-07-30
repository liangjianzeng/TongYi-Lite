import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/model_info.dart';

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(minutes: 2),
    receiveTimeout: const Duration(minutes: 10),
  ));

  static const int maxConcurrentDownloads = 2;

  final Map<String, _ActiveDownload> _activeDownloads = {};
  final Map<String, DateTime> _lastProgressTime = {};

  List<DownloadTask> get activeTasks =>
      _activeDownloads.values.map((d) => d.task).toList();

  Future<void> download(
    ModelConfig model, {
    required void Function(DownloadTask) onProgress,
    Duration progressInterval = const Duration(milliseconds: 500),
  }) async {
    if (_activeDownloads.length >= maxConcurrentDownloads) {
      throw DownloadException('Maximum concurrent downloads reached.');
    }

    final task = DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.sizeBytes,
      startTime: DateTime.now(),
    );

    _activeDownloads[model.id] = _ActiveDownload(task: task);
    onProgress(task);

    try {
      final url = await _resolveUrl(model.mirrors);
      if (url == null) {
        throw DownloadException('All mirrors unreachable.');
      }

      final dir = await _getModelsDir();
      await dir.create(recursive: true);
      final tempFile = File(p.join(dir.path, model.id + '.gguf.tmp'));
      final finalFile = File(p.join(dir.path, model.id + '.gguf'));

      int resumeFrom = 0;
      if (await tempFile.exists()) {
        resumeFrom = await tempFile.length();
        task.downloadedBytes = resumeFrom;
        onProgress(task);
      }

      final headers = <String, dynamic>{};
      if (resumeFrom > 0) {
        headers['Range'] = 'bytes=$resumeFrom-';
      }

      final cancelToken = CancelToken();
      _activeDownloads[model.id] = _ActiveDownload(task: task, cancelToken: cancelToken);

      await _dio.download(
        url,
        tempFile.path,
        options: Options(headers: headers),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (cancelToken.isCancelled) return;
          task.downloadedBytes = resumeFrom + received;
          if (task.totalBytes == 0 && total > 0) {
            task.totalBytes = total;
          }

          final now = DateTime.now();
          final last = _lastProgressTime[model.id];
          if (last == null ||
              now.difference(last).inMilliseconds >= progressInterval.inMilliseconds) {
            _lastProgressTime[model.id] = now;
            onProgress(task);
          }
        },
      );

      final actualSize = await tempFile.length();
      if (actualSize < model.sizeBytes * 0.95 && model.sizeBytes > 0) {
        throw DownloadException('Download incomplete.');
      }

      await tempFile.rename(finalFile.path);
      task.state = DownloadState.completed;
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);
      onProgress(task);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        // Paused or cancelled – don't set failed
        return;
      }
      task.state = DownloadState.failed;
      task.errorMessage = e.toString();
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);
      onProgress(task);
    } catch (e) {
      task.state = DownloadState.failed;
      task.errorMessage = e.toString();
      task.endTime = DateTime.now();
      _lastProgressTime.remove(model.id);

      final dir = await _getModelsDir();
      final tempFile = File(p.join(dir.path, model.id + '.gguf.tmp'));
      if (await tempFile.exists()) {
        try { await tempFile.delete(); } catch (_) {}
      }

      onProgress(task);
    } finally {
      _activeDownloads.remove(model.id);
    }
  }

  Future<void> pause(String modelId) async {
    final active = _activeDownloads[modelId];
    if (active != null && active.task.state == DownloadState.downloading) {
      active.cancelToken.cancel('Paused by user');
      active.task.state = DownloadState.paused;
    }
  }

  Future<void> resume(String modelId) async {
    final model = builtInModels().firstWhere(
      (m) => m.id == modelId,
      orElse: () => throw DownloadException('Model not found.'),
    );

    await download(model, onProgress: (_) {});
  }

  Future<void> cancel(String modelId) async {
    final active = _activeDownloads[modelId];
    if (active != null) {
      try { active.cancelToken.cancel('Cancelled by user'); } catch (_) {}
      active.task.state = DownloadState.idle;
      _activeDownloads.remove(modelId);
    }

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

  Future<String?> _resolveUrl(List<MirrorEntry> mirrors) async {
    for (final mirror in mirrors) {
      try {
        final response = await _dio.head(
          mirror.url,
          options: Options(receiveTimeout: const Duration(seconds: 5)),
        );
        if (response.statusCode == 200 || response.statusCode == 206) {
          return mirror.url;
        }
      } catch (_) { continue; }
    }
    return null;
  }

  Future<Directory> _getModelsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'models'));
  }
}

class _ActiveDownload {
  final DownloadTask task;
  final CancelToken cancelToken;
  _ActiveDownload({required this.task, CancelToken? cancelToken})
      : cancelToken = cancelToken ?? CancelToken();
}

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => 'DownloadError: $message';
}
