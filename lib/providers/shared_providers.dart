import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/inference_service.dart';
import '../services/storage_service.dart';

// Shared providers to avoid circular dependencies between chat_provider, model_provider, etc.
final inferenceServiceProvider = Provider<InferenceService>((ref) => InferenceService());
final storageServiceProvider = Provider<StorageService>((ref) => StorageService());
