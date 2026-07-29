// Model metadata for the Model Hub UI
class ModelInfoDisplay {
  final String id;
  final String name;
  final String type; // text, vision, stt, tts
  final String sizeMB;
  final String recommended; // "推荐" or ""
  final String status; // "已下载", "待下载", "不兼容"
  final String deviceRequirement;
  final String source;

  ModelInfoDisplay({
    required this.id,
    required this.name,
    required this.type,
    required this.sizeMB,
    this.recommended = '',
    this.status = '待下载',
    this.deviceRequirement = '≥4GB RAM',
    this.source = 'ModelScope',
  });
}