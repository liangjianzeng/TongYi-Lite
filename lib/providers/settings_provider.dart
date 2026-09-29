import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/web_search/web_search_provider.dart';
import '../models/api_model.dart';
import '../services/settings_service.dart';

/// 鎸佹湁鎺ㄧ悊寮曟搸璁剧疆锛圙PU 寮€鍏?/ 鍗歌浇灞傛暟锛夛紝骞跺湪鍙樻洿鏃舵寔涔呭寲鍒版湰鍦版枃浠躲€?
class SettingsNotifier extends StateNotifier<InferenceSettings> {
  final SettingsService _service;

  SettingsNotifier(this._service) : super(const InferenceSettings()) {
    _load();
  }

  Future<void> _load() async {
    final loaded = await _service.load();
    if (mounted) state = loaded;
  }

  Future<void> setEnableGpu(bool value) async {
    state = state.copyWith(enableGpu: value);
    await _persist();
  }

  Future<void> setGpuLayers(int value) async {
    // 闃插尽鎬уす绱э紝閬垮厤瓒婄晫鍊艰繘鍏ュ師鐢熷眰銆?
    final clamped = value.clamp(0, 999);
    state = state.copyWith(gpuLayers: clamped);
    await _persist();
  }

  /// 璁剧疆 GPU 鍚庣锛?cpu' / 'vulkan' / 'opencl' / 'auto'锛夈€?
  Future<void> setGpuBackend(String value) async {
    const allowed = {'cpu', 'vulkan', 'opencl', 'auto'};
    if (!allowed.contains(value)) return;
    state = state.copyWith(gpuBackend: value);
    await _persist();
  }

  /// 璁剧疆涓婁笅鏂囧ぇ灏忥紙KV 缂撳瓨绐楀彛锛夈€備笂闄?65536锛屼笅闄?1銆?
  Future<void> setContextSize(int value) async {
    // 闃插尽鎬уす绱э紝閬垮厤瓒婄晫鍊艰繘鍏ュ師鐢熷眰銆?
    final clamped = value.clamp(1, 65536);
    state = state.copyWith(contextSize: clamped);
    await _persist();
  }

  /// 璁剧疆鏄惁鍏佽 Qwen3 鎬濊€冩ā寮忋€傞粯璁ゅ叧闂紙鐩存帴浣滅瓟锛夈€?
  Future<void> setEnableThinking(bool value) async {
    state = state.copyWith(enableThinking: value);
    await _persist();
  }

  /// 璁剧疆鏌愪釜妯″瀷鏄惁鍚敤 MTP锛堝 token 棰勬祴锛夊姞閫熴€傛寜妯″瀷 id 鐙珛寮€鍏筹紝
  /// 浜掍笉褰卞搷鈥斺€斾粎瀵瑰甫 NextN 澶寸殑妯″瀷鐢熸晥锛岀敤鎴峰彲鍦ㄦā鍨嬪垪琛ㄩ€愪釜寮€鍚€?
  Future<void> setEnableMtp(String modelId, bool value) async {
    final updated = Map<String, bool>.from(state.mtpEnabledByModel);
    updated[modelId] = value;
    state = state.copyWith(mtpEnabledByModel: updated);
    await _persist();
  }

  /// 璁剧疆鍏ㄥ眬 MTP 鍔熻兘鎬诲紑鍏筹紙榛樿鍏抽棴锛夈€傚叧闂椂妯″瀷鍗＄墖涓嶆樉绀哄悇妯″瀷 MTP
  /// 寮€鍏筹紝鍔犺浇妯″瀷涔熷己鍒朵笉鍚敤锛涘紑鍚悗妯″瀷鍗＄墖鏄剧ず鏀寔 MTP 妯″瀷鐨勫紑鍏筹紝
  /// 鐢ㄦ埛鍙€愪釜閰嶇疆銆?
  Future<void> setEnableMtpFeature(bool value) async {
    state = state.copyWith(enableMtpFeature: value);
    await _persist();
  }

  /// 璁剧疆鏌愪釜妯″瀷鏄惁鍚敤 dspark 鎶曟満鍔犻€熴€傛寜妯″瀷 id 鐙珛寮€鍏筹紝浜掍笉褰卞搷
  /// 鈥斺€斾粎瀵圭洰褰曞０鏄庝簡鑽夌澶达紙dspark config锛変笖鏂囦欢宸蹭笅杞藉畬鏁寸殑妯″瀷鐢熸晥銆?
  Future<void> setEnableDspark(String modelId, bool value) async {
    final updated = Map<String, bool>.from(state.dsparkEnabledByModel);
    updated[modelId] = value;
    state = state.copyWith(dsparkEnabledByModel: updated);
    await _persist();
  }

  /// 璁剧疆鍏ㄥ眬 dspark 鍔熻兘鎬诲紑鍏筹紙榛樿鍏抽棴锛夈€傚叧闂椂妯″瀷鍗＄墖涓嶆樉绀哄悇妯″瀷
  /// dspark 寮€鍏筹紝鍔犺浇妯″瀷涔熷己鍒朵笉鍚敤锛涘紑鍚悗妯″瀷鍗＄墖鏄剧ず澹版槑浜嗚崏绋垮ご鐨?
  /// 妯″瀷鐨?dspark 寮€鍏筹紝鐢ㄦ埛鍙€愪釜閰嶇疆銆?
  Future<void> setEnableDsparkFeature(bool value) async {
    state = state.copyWith(enableDsparkFeature: value);
    await _persist();
  }

  /// 璁剧疆銆岄粯璁ゅ姞杞姐€嶆ā鍨嬨€備紶 null 琛ㄧず鍙栨秷榛樿銆?
  /// 鎸佷箙鍖栧埌 inference_settings.json锛堜笌 MTP 绛夊叾浠栬缃悓涓€鏂囦欢锛夛紝
  /// 閫€鍑?App 涓嶄細涓㈠け锛涘惎鍔ㄨ嚜鍔ㄥ姞杞介€昏緫鎸夋 id 鍔犺浇妯″瀷銆?
  Future<void> setDefaultModel(String? modelId) async {
    if (state.defaultModelId == modelId) return;
    // 浼?null 琛ㄧず鍙栨秷榛樿锛氬繀椤绘樉寮忕疆 clearDefaultModel=true锛?
    // 鍚﹀垯 copyWith 閲岀殑 `defaultModelId ?? this.defaultModelId` 浼氬悶鎺?null锛?
    // 瀵艰嚧涓€鏃﹂€夎繃灏卞啀涔熸棤娉曞弽閫夛紙鏃у€艰淇濈暀锛夈€?
    state = state.copyWith(
        defaultModelId: modelId, clearDefaultModel: modelId == null);
    await _persist();
  }

  // ---------------------------------------------------------------
  // OpenAI 鍏煎杩滅▼妯″瀷锛圓PI 鎺ュ叆锛?
  // ---------------------------------------------------------------

  /// 鏂板涓€涓?API 妯″瀷閰嶇疆銆?
  Future<void> addApiModel(ApiModelConfig config) async {
    state = state.copyWith(
      apiModels: [...state.apiModels, config],
    );
    await _persist();
  }

  /// 鏇存柊涓€涓凡鏈?API 妯″瀷閰嶇疆锛堟寜 id 瀹氫綅锛涗笉瀛樺湪鍒欏拷鐣ワ級銆?
  Future<void> updateApiModel(ApiModelConfig config) async {
    state = state.copyWith(
      apiModels: [
        for (final m in state.apiModels)
          if (m.id == config.id) config else m,
      ],
    );
    await _persist();
  }

  /// 鍒犻櫎涓€涓?API 妯″瀷閰嶇疆锛涜嫢鍒犻櫎鐨勬槸褰撳墠婵€娲绘ā鍨嬶紝鑷姩鍋滅敤 API銆?
  Future<void> deleteApiModel(String id) async {
    final removedActive = state.activeApiModelId == id;
    state = state.copyWith(
      apiModels: state.apiModels.where((m) => m.id != id).toList(),
      activeApiModelId: removedActive ? null : state.activeApiModelId,
      clearActiveApiModel: removedActive,
    );
    await _persist();
  }

  /// 婵€娲?鍋滅敤鏌愪釜 API 妯″瀷銆備紶 null 琛ㄧず鍋滅敤锛堜笉鍚敤 API 鎺ュ叆锛夈€?
  /// 璺敱绛栫暐锛氭湰鍦版ā鍨嬩紭鍏堬紝浠呭綋鏈湴涓嶅彲鐢ㄦ椂鎵嶈蛋婵€娲荤殑 API銆?
  Future<void> setActiveApiModel(String? modelId) async {
    // 鏍￠獙锛氫粎鍏佽婵€娲诲垪琛ㄥ唴瀛樺湪鐨?id锛堟垨 null 鍋滅敤锛夈€?
    if (modelId != null &&
        !state.apiModels.any((m) => m.id == modelId)) {
      return;
    }
    if (state.activeApiModelId == modelId) return;
    state = state.copyWith(
        activeApiModelId: modelId, clearActiveApiModel: modelId == null);
    await _persist();
  }

  // ---------------------------------------------------------------
  // 鏅鸿兘浣擄紙Agent锛?
  // ---------------------------------------------------------------

  /// 鏅鸿兘浣撴ā寮忔€诲紑鍏炽€?
  Future<void> setAgentEnabled(bool value) async {
    state = state.copyWith(agentEnabled: value);
    await _persist();
  }

  /// 鏄惁鍚敤鏂版櫤鑳戒綋妯″紡锛圥hase 0 閲嶅啓鐨勪簨浠舵簮 ReactLoopAgent锛夛紱
  /// 鍏抽棴鍒欏洖閫€鏃?runAgent 閫昏緫锛堝彲鍥為€€寮€鍏筹級銆?
  Future<void> setUseNewAgentMode(bool value) async {
    state = state.copyWith(useNewAgentMode: value);
    await _persist();
  }

  /// 鎸囧畾/鍙栨秷鏅鸿兘浣撻┍鍔ㄦā鍨嬨€?
  /// - source='local' 鈫?[modelId] 涓烘湰鍦版ā鍨嬬洰褰?id锛?
  /// - source='api' 鈫?[modelId] 涓?API 妯″瀷閰嶇疆 id锛?
  /// - 浼?(null, null) 琛ㄧず鍙栨秷鎸囧畾锛岃窡闅忛粯璁よ矾鐢憋紙鏈湴浼樺厛锛孉PI 鍏滃簳锛夈€?
  Future<void> setAgentModel(String? source, String? modelId) async {
    if (source == null && modelId == null) {
      // 鍙栨秷鎸囧畾锛氬繀椤绘樉寮?clearAgentModel=true锛屽惁鍒?copyWith 鍚炴帀 null銆?
      if (state.agentModelId == null) return;
      state = state.copyWith(clearAgentModel: true);
      await _persist();
      return;
    }
    if (source != 'local' && source != 'api') return;
    if (modelId == null || modelId.isEmpty) return;
    // API 妯″瀷蹇呴』瀛樺湪浜庨厤缃垪琛ㄥ唴锛屽惁鍒欐嫆缁濄€?
    if (source == 'api' && !state.apiModels.any((m) => m.id == modelId)) {
      return;
    }
    if (state.agentModelSource == source && state.agentModelId == modelId) {
      return;
    }
    state = state.copyWith(
        agentModelSource: source, agentModelId: modelId);
    await _persist();
  }

  /// 鏅鸿兘浣撴ā寮忎笂涓嬫枃闀垮害锛坣_ctx锛夈€傚す绱у埌 1~65536銆?
  Future<void> setAgentNctx(int value) async {
    final clamped = value.clamp(1, 65536);
    state = state.copyWith(agentNctx: clamped);
    await _persist();
  }

  /// 宸ュ叿寰幆杞涓婇檺锛?~24锛屼笌寮曟搸 AgentConfig assert 瀵归綈锛夈€?
  Future<void> setAgentMaxRounds(int value) async {
    final clamped = value.clamp(1, 24);
    state = state.copyWith(agentMaxRounds: clamped);
    await _persist();
  }

  /// web_search 每回合调用上限（1~10，DSH max_uses 语义）。
  Future<void> setAgentMaxSearchesPerTurn(int value) async {
    final clamped = value.clamp(1, 10);
    state = state.copyWith(agentMaxSearchesPerTurn: clamped);
    await _persist();
  }

  /// 姣忚疆鐢熸垚 token 棰勭畻锛?28~16384锛?6k 涓婇檺鎸夐渶閰嶇疆锛夈€?
  Future<void> setAgentTokensPerRound(int value) async {
    final clamped = value.clamp(128, 16384);
    state = state.copyWith(agentTokensPerRound: clamped);
    await _persist();
  }

  /// 鍗曞伐鍏锋墽琛岃秴鏃讹紙姣锛?s~120s锛夈€?
  Future<void> setAgentToolTimeoutMs(int value) async {
    final clamped = value.clamp(1000, 120000);
    state = state.copyWith(agentToolTimeoutMs: clamped);
    await _persist();
  }

  /// 骞惰宸ュ叿璋冪敤寮€鍏炽€?
  Future<void> setAgentAllowParallelTools(bool value) async {
    state = state.copyWith(agentAllowParallelTools: value);
    await _persist();
  }

  /// 骞惰宸ュ叿骞跺彂涓婇檺锛?~8锛涜繍琛屾湡鍐嶆寜妯″瀷鑳藉姏澶圭揣锛夈€?
  Future<void> setAgentMaxParallel(int value) async {
    final clamped = value.clamp(2, 8);
    state = state.copyWith(agentMaxParallel: clamped);
    await _persist();
  }

  /// 鏅鸿兘浣撶敓鎴愭俯搴︼紙0~2锛夈€?
  Future<void> setAgentTemperature(double value) async {
    state = state.copyWith(agentTemperature: value.clamp(0.0, 2.0));
    await _persist();
  }

  /// 瀛愪唬鐞嗗伐鍏锋敞鍐屽紑鍏炽€?
  Future<void> setAgentSubagentEnabled(bool value) async {
    state = state.copyWith(agentSubagentEnabled: value);
    await _persist();
  }

  /// 涓婁笅鏂囪秴闄愯嚜鍔ㄥ帇缂╁紑鍏炽€?
  Future<void> setAgentCompactEnabled(bool value) async {
    state = state.copyWith(agentCompactEnabled: value);
    await _persist();
  }

  /// 瓒呴暱宸ュ叿杈撳嚭婧㈠啓寮€鍏炽€?
  Future<void> setAgentSpillEnabled(bool value) async {
    state = state.copyWith(agentSpillEnabled: value);
    await _persist();
  }

  /// 鑱旂綉鎼滅储宸ュ叿鎬诲紑鍏炽€?
  Future<void> setWebSearchEnabled(bool value) async {
    state = state.copyWith(webSearchEnabled: value);
    await _persist();
    _reapplyWebSearchProvider();
  }

  // ---- 鑱旂綉鎼滅储锛圫earXNG锛夊疄渚嬮厤缃?----
  // 姣忛」淇濆瓨鍚庣珛鍗崇儹鏇存柊 WebSearchSeam 閲岀殑 provider锛堥厤缃湭鍙樺垯澶嶇敤瀹炰緥锛夛紝
  // 鏀瑰湴鍧€鏃犻渶閲嶅惎搴旂敤銆?

  /// SearXNG 瀹炰緥鍦板潃锛屽 `http://192.168.1.20:8080`锛涚┖ = 鏈厤缃€?
  Future<void> setWebSearchSearXngBaseUrl(String value) async {
    state = state.copyWith(webSearchSearXngBaseUrl: value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// SearXNG API key锛堢鏈夊疄渚嬫墠闇€瑕侊紱绌?= 鏃犲瘑閽ワ級銆?
  Future<void> setWebSearchSearXngApiKey(String value) async {
    state = state.copyWith(
        webSearchSearXngApiKey: value.trim().isEmpty ? null : value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 寮曟搸鐧藉悕鍗曪紙閫楀彿鍒嗛殧锛屽 `bing,sogou`锛夛紱绌?= 鐢卞疄渚嬪喅瀹氬叏閮ㄥ紩鎿庛€?
  /// 瀹炰緥涓婂瓨鍦ㄤ笉鍙揪寮曟搸鏃讹紝鍙～鍙揪寮曟搸鍙妸鎼滅储浠庝簩鍗佺绾ч檷鍒扮绾с€?
  Future<void> setWebSearchSearXngEngines(String value) async {
    state = state.copyWith(
        webSearchSearXngEngines: value.trim().isEmpty ? null : value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 鎼滅储璇█锛堝 `zh-CN`锛夛紱绌?= 涓嶆寚瀹氥€?
  Future<void> setWebSearchSearXngLanguage(String value) async {
    state = state.copyWith(
        webSearchSearXngLanguage: value.trim().isEmpty ? null : value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 鍗曟鎼滅储鏈€澶氳繑鍥炴潯鏁帮紙1~20锛夈€?
  Future<void> setWebSearchSearXngMaxResults(int value) async {
    state = state.copyWith(webSearchSearXngMaxResults: value.clamp(1, 20));
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 鍗曟鎼滅储瓒呮椂锛堟绉掞紝3s~120s锛夈€?
  Future<void> setWebSearchSearXngTimeoutMs(int value) async {
    state = state.copyWith(webSearchSearXngTimeoutMs: value.clamp(3000, 120000));
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 鎸夊綋鍓嶈缃噸寤鸿仈缃戞悳绱?provider锛堝唴瀹规湭鍙樻椂 [applySearXNGProviderFromSettings]
  /// 鐩存帴澶嶇敤鐜版湁瀹炰緥锛屼笉浼氭墦鏂繛鎺ユ睜锛夈€?
  void _reapplyWebSearchProvider() {
    try {
      applySearXNGProviderFromSettings(state);
    } catch (_) {
      // 鐑洿鏂板け璐ヤ笉褰卞搷璁剧疆鏈韩鐨勪繚瀛橈細涓嬩竴杞璇濇瀯寤烘敞鍐岃〃鏃朵細鍐嶈瘯涓€娆°€?
    }
  }

  /// shell 鎵ц宸ュ叿寮€鍏炽€?
  Future<void> setAgentShellEnabled(bool value) async {
    state = state.copyWith(agentShellEnabled: value);
    await _persist();
  }

  /// python_exec 宸ュ叿寮€鍏炽€?
  Future<void> setAgentPythonEnabled(bool value) async {
    state = state.copyWith(agentPythonEnabled: value);
    await _persist();
  }

  /// 娌欑瀹屾暣鏂囦欢璁块棶鎺堟潈锛坉anger-full-access 鍓嶇疆锛夈€?
  Future<void> setAgentFullFileAccess(bool value) async {
    state = state.copyWith(agentFullFileAccess: value);
    await _persist();
  }

  /// 闀挎湡璁板繂寮€鍏筹紙榛樿鍏抽棴锛氳法浼氳瘽璁板繂鍙兘绉疮鍋跺彂閿欒锛夈€?
  Future<void> setAgentMemoryEnabled(bool value) async {
    state = state.copyWith(agentMemoryEnabled: value);
    await _persist();
  }

  /// 鏄惁榛樿鍔犺浇瑙嗚鎶曞奖鍣紙mmproj锛夈€?
  Future<void> setAutoLoadMmproj(bool value) async {
    state = state.copyWith(autoLoadMmproj: value);
    await _persist();
  }

  /// GPU/CPU 鍗犵敤鐜囩洃鎺у憟鐜板紑鍏炽€?
  Future<void> setShowResourceMonitor(bool value) async {
    state = state.copyWith(showResourceMonitor: value);
    await _persist();
  }
  /// OOM 鍐呭瓨瀹堝崼鎬诲紑鍏炽€傚叧闂?= 鍔犺浇鍓嶄笉鍐嶆嫆缁濊秴澶фā鍨嬶紙鏈夋暣鏈烘鏈洪闄╋級銆?
  Future<void> setOomGuardEnabled(bool value) async {
    state = state.copyWith(oomGuardEnabled: value);
    await _persist();
  }

  /// OOM 棰勬浣欓噺锛圡B锛?~4096锛夈€傚姞杞藉墠 MemAvailable 鎵ｉ櫎璇ヤ綑閲忓悗涓庢ā鍨嬩綋绉?
  /// 姣旇緝锛涜皟灏忔洿瀹规槗鏀捐繃鏋侀檺澶фā鍨嬶紝璋冨ぇ鏇翠繚瀹堛€?
  Future<void> setOomPreHeadroomMb(int value) async {
    state = state.copyWith(oomPreHeadroomMb: value.clamp(0, 4096));
    await _persist();
  }

  /// OOM 鍔犺浇鍚庝綑閲忥紙MB锛?~4096锛夈€侹V cache / 鍥捐绠楃紦鍐查绠?=
  /// MemAvailable - 璇ヤ綑閲忥紱璋冨皬缁?KV 鏇村ぇ绌洪棿锛岃皟澶ф洿淇濆畧銆?
  Future<void> setOomPostHeadroomMb(int value) async {
    state = state.copyWith(oomPostHeadroomMb: value.clamp(0, 4096));
    await _persist();
  }


  /// 鍗犵敤鐜囬噰鏍峰懆鏈燂紙绉掞紝0~30锛? = 浠呮帹鐞嗘椂閲囨牱锛夈€?
  Future<void> setResourceSampleIntervalSec(int value) async {
    final clamped = value.clamp(0, 30);
    state = state.copyWith(resourceSampleIntervalSec: clamped);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _service.save(state);
    } catch (e) {
      // 鎸佷箙鍖栧け璐ヤ笉搴旈樆鏂?UI 浜や簰锛涘唴瀛樼姸鎬佸凡鏇存柊銆?
      // 璁板綍鏃ュ織渚夸簬瀹氫綅锛堟鍓嶅畬鍏ㄩ潤榛橈紝澶辫触鏃剁敤鎴锋棤鎰熺煡锛夈€?
      debugPrint('[Settings] persist failed: $e');
    }
  }
}

final settingsServiceProvider =
    Provider<SettingsService>((ref) => SettingsService());

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, InferenceSettings>((ref) {
  final service = ref.watch(settingsServiceProvider);
  return SettingsNotifier(service);
});
