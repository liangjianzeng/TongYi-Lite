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

  // Extended timeouts for large model downloads (up to 2GB+)
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(minutes: 3),
    receiveTimeout: const Duration(hours: 2), // Very long timeout for large files
    sendTimeout: const Duration(minutes: 5),
  ));

  // 最多同时下载 2 个模型（CDN 实测可承受）。注意：每个视觉模型内部是「主 gguf
  // + mmproj」顺序下载，占用同一槽位；故 2 并发 = 最多 2 个模型并行。
  static const int maxConcurrentDownloads = 2;

  final Map<String, _ActiveDownload> _activeDownloads = {};
  final Map<String, DateTime> _lastProgressTime = {};

  /// 单次下载允许的最大自动重试次数（含首次）。网络抖动/连接被 CDN 中途
  /// 关闭时，会自动断点续传重试，不必用户手动点「重试」。
  static const int _maxAttempts = 8;

  List<DownloadTask> get activeTasks =>
      _activeDownloads.values.map((d) => d.task).toList();

  Future<void> download(
    ModelConfig model, {
    required void Function(DownloadTask) onProgress,
    Duration progressInterval = const Duration(milliseconds: 500),
    DownloadTask? existingTask, // Optional task to reuse (e.g., from provider's initialTask)
  }) async {
    // ---- Concurrency guard ----
    final sameModel = _activeDownloads[model.id];
    if (sameModel != null) {
      // Already tracked for this model: ignore a duplicate start while it is
      // still downloading; clear a stale (paused/completed) entry so a resume
      // or retry can proceed without tripping the capacity guard.
      if (sameModel.task.state == DownloadState.downloading) return;
      _activeDownloads.remove(model.id);
    }
    if (_activeDownloads.length >= maxConcurrentDownloads) {
      throw DownloadException('Only one download at a time.');
    }

    final task = existingTask ?? DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.sizeBytes, // preset so progress shows immediately
      startTime: DateTime.now(),
    );

    _activeDownloads[model.id] = _ActiveDownload(task: task);
    onProgress(task);

    final dir = await _getModelsDir();
    await dir.create(recursive: true);

    try {
      // ---- 主模型 gguf ----
      // 若主 gguf 已在磁盘且完整（存在、大小达标、无残留 .tmp），则跳过下载，
      // 直接进入 mmproj 阶段。这样「已下主模型、缺投影器」的视觉模型点「下载」
      // 时只补下 mmproj，不会把多 GB 的主 gguf 再拉一遍。
      final ggufTarget = _DownloadTarget(
        mirrors: model.mirrors, sizeBytes: model.sizeBytes, suffix: '.gguf',
      );
      final ggufTemp = File(p.join(dir.path, model.id + ggufTarget.suffix + '.tmp'));
      final ggufFinal = File(p.join(dir.path, model.id + ggufTarget.suffix));
      final ggufComplete = await ggufFinal.exists() &&
          !(await ggufTemp.exists()) &&
          (model.sizeBytes == 0 ||
           (await ggufFinal.length()) >= (model.sizeBytes * 0.99).round());
      if (ggufComplete) {
        debugPrint('[DownloadService] ${model.id} 主 gguf 已完整，跳过主模型下载');
      } else {
        await _runDownloadLoop(
          model, task, ggufTarget, ggufTemp, ggufFinal, onProgress, progressInterval,
        );
      }

      // ---- mmproj 投影器（text+mmproj 两文件形态）----
      // 主模型完成后顺序下载投影器。mmproj 下载失败不删除已下好的主 gguf
      // （模型仍可文本推理），但整任务标记为失败。
      final mm = model.mmproj;
      if (mm != null) {
        // 进度重置为 mmproj 阶段，避免与主模型体积叠加导致进度错乱。
        task.totalBytes = mm.sizeBytes;
        task.downloadedBytes = 0;
        task.state = DownloadState.downloading;
        onProgress(task);
        final mmprojTarget = _DownloadTarget(
          mirrors: mm.mirrors, sizeBytes: mm.sizeBytes, suffix: '.mmproj',
        );
        final mmprojTemp = File(p.join(dir.path, model.id + mmprojTarget.suffix + '.tmp'));
        final mmprojFinal = File(p.join(dir.path, model.id + mmprojTarget.suffix));
        // 与主 gguf 同样的「已完整则跳过」：若 mmproj 已完整存在，直接落完成态，
        // 不再重复拉取已有投影器（此前缺此检查，点「下载」会无条件重下 mmproj）。
        final mmprojComplete = await mmprojFinal.exists() &&
            !(await mmprojTemp.exists()) &&
            (mm.sizeBytes == 0 ||
             (await mmprojFinal.length()) >= (mm.sizeBytes * 0.99).round());
        if (mmprojComplete) {
          final done = await mmprojFinal.length();
          debugPrint('[DownloadService] ${model.id} mmproj 已完整，跳过投影器下载');
          task.totalBytes = done;
          task.downloadedBytes = done;
          task.state = DownloadState.completed;
          task.endTime = DateTime.now();
          onProgress(task);
        } else {
          await _runDownloadLoop(
            model, task, mmprojTarget, mmprojTemp, mmprojFinal, onProgress, progressInterval,
          );
        }
      }
    } finally {
      // CRITICAL: the entry must be dropped no matter how we leave, otherwise
      // the `maxConcurrentDownloads` guard stays permanently saturated after
      // the first finished download and every later start throws
      // "Only one download at a time." — which looked like a dead button.
      // Exception: a *paused* task keeps its slot so resume() can reuse it.
      if (task.state != DownloadState.paused) {
        _activeDownloads.remove(model.id);
      }
    }
  }

  Future<void> _runDownloadLoop(
    ModelConfig model,
    DownloadTask task,
    _DownloadTarget target,
    File tempFile,
    File finalFile,
    void Function(DownloadTask) onProgress,
    Duration progressInterval,
  ) async {
    // ---- 自动重试循环：连接中断时保留已下载的 .tmp 并断点续传 ----
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      final cancelToken = CancelToken();
      _activeDownloads[model.id] = _ActiveDownload(task: task, cancelToken: cancelToken);

      try {
        // Step 1: 解析镜像（是否支持 HTTP Range）。
        // 若磁盘已有部分 .tmp 且长度 > 0，则必须选支持 Range 的镜像才能续传；
        // 没有这样的镜像时退回「整段重下」并丢弃旧 .tmp。
        final hasPartial = await tempFile.exists() && (await tempFile.length()) > 0;

        _UrlInfo? urlInfo;
        bool supportsRange = false;
        int downloadedSoFar = 0;

        if (hasPartial) {
          downloadedSoFar = await tempFile.length();
          task.downloadedBytes = downloadedSoFar;
          if (target.sizeBytes > 0) task.totalBytes = target.sizeBytes;
          onProgress(task);

          urlInfo = await _resolveUrl(target.mirrors, requireRange: true);
          if (urlInfo != null) {
            supportsRange = true;
            debugPrint('[DownloadService] Attempt $attempt: resuming '
                'from ${_formatBytes(downloadedSoFar)} via Range-capable mirror');
          } else {
            // 没有支持 Range 的镜像 → 无法续传，整段重下。
            debugPrint('[DownloadService] Attempt $attempt: no Range mirror, '
                'restarting fresh');
            await tempFile.delete();
            downloadedSoFar = 0;
            task.downloadedBytes = 0;
            urlInfo = await _resolveUrl(target.mirrors, requireRange: false);
          }
        } else {
          urlInfo = await _resolveUrl(target.mirrors, requireRange: false);
        }

        if (urlInfo == null) {
          throw DownloadException('所有镜像当前不可达，请检查网络后重试。');
        }

        // Step 2: 已完成？直接落到最终文件。
        if (hasPartial && target.sizeBytes > 0 &&
            (await tempFile.length()) >= target.sizeBytes) {
          // 用实文件大小（可能大于估算的 sizeBytes），进度恒为 100%。
          final done = await tempFile.length();
          task.totalBytes = done;
          task.downloadedBytes = done;
          await tempFile.rename(finalFile.path);
          task.state = DownloadState.completed;
          task.endTime = DateTime.now();
          onProgress(task);
          return;
        }

        // Step 3: 下载主体。支持 Range 且有残留则断点续传，否则整段下载。
        if (supportsRange && downloadedSoFar > 0) {
          await _downloadRange(
            urlInfo.url,
            tempFile,
            downloadedSoFar,
            target.sizeBytes,
            task,
            cancelToken,
            onProgress,
            progressInterval,
          );
        } else {
          if (task.totalBytes == 0) task.totalBytes = target.sizeBytes;
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

          // 服务器返回的实际 Content-Length（catalog 的 sizeBytes 只是估算，可能
          // 偏小导致进度超 100%，也可能偏大导致完整度误判，因此以服务器为准）。
          final headerTotalStr = response.headers.value('content-length');
          int? headerTotal;
          if (headerTotalStr != null) {
            headerTotal = int.tryParse(headerTotalStr);
            if (headerTotal != null && headerTotal > 0) {
              task.totalBytes = headerTotal;
              debugPrint('[DownloadService] Using Content-Length from headers: $headerTotal bytes');
            }
          }

          final raf = tempFile.openSync(mode: FileMode.writeOnlyAppend);
          int received = downloadedSoFar;
          DateTime? lastProgress;
          try {
            await for (final chunk in body.stream) {
              if (cancelToken.isCancelled) break;
              await raf.writeFrom(chunk);
              received += chunk.length;
              task.downloadedBytes = received;
              final now = DateTime.now();
              if (lastProgress == null ||
                  now.difference(lastProgress) >= progressInterval) {
                lastProgress = now;
                onProgress(task);
              }
            }
          } finally {
            await raf.close();
          }

          // 完整度校验：若服务器给出 Content-Length 但实际字节数不足，说明连接
          // 中途被静默截断（无异常直接结束流）。此时绝不能把残缺文件提升为
          // 最终 .gguf/.mmproj —— 否则缓存发现会把它当成「已缓存」，或尺寸
          // 不达标被误判「未下载」。抛异常走重试/清理 .tmp 路径。
          if (headerTotal != null && headerTotal > 0 && received < headerTotal) {
            throw DownloadException(
              '下载不完整（${_formatBytes(received)}/${_formatBytes(headerTotal)}），自动续传重试',
            );
          }

          // 整段下载结束后，用实际写入字节数作为 totalBytes（与 downloadedBytes
          // 一致，进度即 100%），不再依赖估算的 sizeBytes。
          task.totalBytes = received;
          onProgress(task);
        }

        // Step 4: 校验产物非空。
        final actualSize = await tempFile.length();
        if (actualSize == 0) {
          throw DownloadException('Download produced empty file');
        }

        // Step 5: 提升 .tmp 为最终文件。
        await tempFile.rename(finalFile.path);
        // 完成态以实文件大小为准，进度恒为 100%。
        task.downloadedBytes = actualSize;
        task.totalBytes = actualSize > task.totalBytes ? actualSize : task.totalBytes;
        task.state = DownloadState.completed;
        task.endTime = DateTime.now();
        _lastProgressTime.remove(model.id);
        onProgress(task);
        return; // 成功
      } on DioException catch (e) {
        // 用户暂停/取消：保留 .tmp 以便后续续传，直接退出（不标记为失败）。
        if (CancelToken.isCancel(e) || cancelToken.isCancelled) {
          return;
        }
        if (attempt < _maxAttempts) {
          // 瞬时连接中断：保留 .tmp，短暂停顿后断点续传重试。
          task.errorMessage = '连接中断，正在自动重试 ($attempt/${_maxAttempts - 1})…';
          onProgress(task);
          await Future.delayed(const Duration(seconds: 3));
          // 若重试等待期间用户点了暂停，则中止重试。
          if (task.state == DownloadState.paused) return;
          continue;
        }
        await _fail(task, _cleanErrorMessage(e.toString()), model.id, deletePartial: true);
        onProgress(task);
      } catch (e) {
        if (attempt < _maxAttempts) {
          task.errorMessage = '下载中断，正在自动重试 ($attempt/${_maxAttempts - 1})…';
          onProgress(task);
          await Future.delayed(const Duration(seconds: 3));
          if (task.state == DownloadState.paused) return;
          continue;
        }
        await _fail(task, _cleanErrorMessage(e.toString()), model.id, deletePartial: true);
        onProgress(task);
      }
    }
  }

  /// 标记任务失败并（可选）清理残留 .tmp。
  Future<void> _fail(DownloadTask task, String message, String modelId, {bool deletePartial = true}) async {
    task.state = DownloadState.failed;
    task.errorMessage = message;
    task.endTime = DateTime.now();
    _lastProgressTime.remove(modelId);
    if (deletePartial) {
      try {
        final dir = await _getModelsDir();
        // 同时清理主模型与 mmproj 的残留 .tmp（已重命名的最终文件不删，
        // 以便 mmproj 失败时主 gguf 仍可文本推理）。
        for (final suffix in ['.gguf.tmp', '.mmproj.tmp']) {
          final tmp = File(p.join(dir.path, modelId + suffix));
          if (await tmp.exists()) await tmp.delete();
        }
      } catch (_) {}
    }
  }

  /// Download a byte range [start, ∞) and append to [file]. Correctly implements
  /// resume over mirrors that return 206 (e.g. hf-mirror.com / HuggingFace CDN).
  /// 若服务器忽略 Range（返回 200）则退回整段写入。
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

    // 206 = 部分内容（按 Range 续传）；200 = 服务器忽略 Range，整段重下。
    final isPartial = response.statusCode == 206;
    // 服务器 Content-Length：206 时是「剩余字节」，整文件应为 start + 该值。
    final headerTotalStr = response.headers.value('content-length');
    final headerTotal = int.tryParse(headerTotalStr ?? '');
    final expectedTotal =
        (isPartial && headerTotal != null) ? (start + headerTotal) : headerTotal;
    final raf = file.openSync(mode: isPartial ? FileMode.append : FileMode.write);
    try {
      int received = isPartial ? start : 0;
      if (!isPartial) task.downloadedBytes = 0;
      await for (final chunk in body.stream) {
        if (cancelToken.isCancelled) break;
        await raf.writeFrom(chunk);
        received += chunk.length;
        task.downloadedBytes = received;
        if (task.totalBytes == 0) task.totalBytes = total;
        _emitProgress(task, progressInterval, onProgress);
      }
      // 完整度校验：服务器给出 Content-Length 但实际字节不足 → 流被静默截断。
      // 不提升为最终文件，抛异常走重试/清理路径，避免残缺文件被当「已缓存」。
      if (expectedTotal != null && expectedTotal > 0 && received < expectedTotal) {
        throw DownloadException(
          '续传不完整（${_formatBytes(received)}/${_formatBytes(expectedTotal)}），自动续传重试',
        );
      }
      // 续传结束后用实际累计字节数作为 totalBytes，与 downloadedBytes 一致。
      task.totalBytes = received;
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

    // Reuse the unified [download] entry point. It detects the existing `.tmp`
    // partial on disk and resumes from there (the .tmp holds the true resume
    // data, so we don't need to carry progress in memory).
    final task = DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.sizeBytes,
      startTime: DateTime.now(),
    );

    await download(model, existingTask: task, onProgress: onProgress);
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
    for (final suffix in ['.gguf.tmp', '.gguf', '.mmproj.tmp', '.mmproj']) {
      final file = File(p.join(dir.path, modelId + suffix));
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
  }

  Future<void> deleteModel(String modelId) async {
    final dir = await _getModelsDir();
    // 主模型 + mmproj 投影器一并删除。
    for (final suffix in ['.gguf', '.gguf.tmp', '.mmproj', '.mmproj.tmp']) {
      final file = File(p.join(dir.path, modelId + suffix));
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
  }

  /// Resolve a reachable mirror, returning whether it supports HTTP Range.
  ///
  /// When [requireRange] is true, a mirror that is reachable but does NOT
  /// support Range requests is skipped (we keep looking), because the caller
  /// needs to resume a partial download and must issue a `Range` request.
  ///
  /// 探测用一次极小的 `Range: bytes=0-0` 请求完成：既验证可达性，也顺带确认
  /// Range 支持，避免像旧实现那样用 GET + ResponseType.bytes 把整个多 GB
  /// 文件拉进内存只为读响应头（Bonsai 27B 等大模型会直接 OOM）。
  Future<_UrlInfo?> _resolveUrl(List<MirrorEntry> mirrors, {bool requireRange = false}) async {
    for (final mirror in mirrors) {
      final info = await _probeMirror(mirror);
      if (info == null) continue;
      if (requireRange && !info.supportsRange) {
        debugPrint('[DownloadService] Mirror ${mirror.source} reachable but no Range support, skipping');
        continue;
      }
      return info;
    }
    return null; // All mirrors unreachable
  }

  /// 用 `Range: bytes=0-0` 探测单个镜像：一次只取 1 字节。
  /// 返回 206 → 支持 Range；200 → 不支持（整段下载）；其余/异常 → 不可达。
  Future<_UrlInfo?> _probeMirror(MirrorEntry mirror) async {
    try {
      final response = await _dio.get<ResponseBody>(
        mirror.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      _UrlInfo? info;
      if (response.statusCode == 206) {
        info = _UrlInfo(url: mirror.url, supportsRange: true);
      } else if (response.statusCode == 200) {
        // 服务器忽略了 Range 头 → 仅支持整段下载，无断点续传。
        info = _UrlInfo(url: mirror.url, supportsRange: false);
      }
      // 排空极小的响应体，释放连接。
      try { await response.data?.stream.drain<void>(); } catch (_) {}
      if (info != null) {
        debugPrint('[DownloadService] Mirror ${mirror.source} OK '
            '(status ${response.statusCode}, Range: ${info.supportsRange})');
        return info;
      }
    } catch (e) {
      debugPrint('[DownloadService] Mirror ${mirror.source} probe error: $e');
    }
    return null;
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
    // 连接被 CDN 中途关闭 —— 现在已经内置自动断点续传重试，
    // 只有多次重试仍失败才会走到这里，不再误导用户是「CDN 不支持续传」。
    if (error.contains('Connection closed while receiving data')) {
      return '下载连接多次中断，已自动续传仍失败，请稍后重试';
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

/// 一次下载目标：主模型 `.gguf` 或 mmproj 投影器 `.mmproj`。
class _DownloadTarget {
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String suffix;

  const _DownloadTarget({
    required this.mirrors,
    required this.sizeBytes,
    required this.suffix,
  });
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
