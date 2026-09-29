import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/api_model.dart';

/// 鎺ㄧ悊寮曟搸鐩稿叧鐨勭敤鎴疯缃紙GPU 鍔犻€熷紑鍏?+ 鍗歌浇灞傛暟 + 鍚庣閫夋嫨 + 涓婁笅鏂囧ぇ灏忥級銆?
///
/// 榛樿鍏抽棴 GPU 鍔犻€燂紙鐢ㄦ埛鍙湪璁剧疆椤靛紑鍚紱寮€鍚悗 auto 浼樺厛閫?OpenCL锛?
/// 涓?Vulkan 鍦?Adreno 825 涓婂疄娴嬬瓑鏁堛€佸潎鏃犳暟鍊煎穿鍧忥級锛屽嵏杞藉眰鏁伴粯璁?100
/// 锛堝叏閲忓嵏杞斤紱llama.cpp 浼氳嚜鍔?clamp 鍒版ā鍨嬪疄闄呭眰鏁帮級锛?
/// 涓婁笅鏂囧ぇ灏忛粯璁?4096锛屾渶澶?65536銆?
class InferenceSettings {
  final bool enableGpu;
  final int gpuLayers;
  final int contextSize;

  /// 鏄惁鍏佽 Qwen3 鎬濊€冩ā寮忥紙<think> 閾撅級銆傞粯璁ゅ叧闂?= 鐩存帴浣滅瓟锛屽搷搴旀洿蹇€?
  final bool enableThinking;

  /// GPU 鍚庣閫夋嫨锛?cpu' / 'vulkan' / 'opencl' / 'auto'銆?
  /// 榛樿 'auto'锛氫紭鍏?OpenCL锛圓dreno 825 涓?OpenCL 椹卞姩楂樺害浼樺寲锛屼笌 Vulkan
  /// 瀹炴祴鍚炲悙鍑犱箮绛変环锛涗袱鑰呭潎缁忕湡鏈洪獙璇佸彲姝ｅ父杈撳嚭锛屾棤鏁板€煎穿鍧忥級銆傜敤鎴峰彲鍒囧埌
  /// Vulkan 瀵规瘮銆俵lama.rn 鍦?Android 涓婂嵆鐢?OpenCL 鍚庣锛孉dreno 700+ 鍙敤銆?
  final String gpuBackend;

  /// 鏄惁鍚敤 MTP锛堝 token 棰勬祴锛夊姞閫燂紝鎸夋ā鍨?id 閫愪釜寮€鍏筹紙榛樿鍏ㄥ叧锛夈€?
  /// 浠呭甯?NextN 澶寸殑妯″瀷鐢熸晥鈥斺€擬TP 鐨?draft/verify/process 涓夋瀹屾暣鍓嶅悜
  /// 寮€閿€鍦ㄧ渚ч€氬父涓嶅垝绠楋紝鐢ㄦ埛鍙湪妯″瀷鍒楄〃瀵规瘡涓敮鎸佺殑妯″瀷鎵嬪姩寮€鍚紝
  /// 浜掍笉褰卞搷銆?
  final Map<String, bool> mtpEnabledByModel;

  /// 鍏ㄥ眬 MTP 鍔熻兘鎬诲紑鍏筹紙榛樿鍏抽棴锛夈€傜敤浜庢帶鍒舵暣涓?APP 鐨?MTP 鏄惁
  /// 銆屽彲瑙佸彲鐢ㄣ€嶏細
  /// - 鍏抽棴锛堥粯璁わ級锛氭ā鍨嬪崱鐗囦笉鏄剧ず鍚勬ā鍨嬬殑 MTP 寮€鍏筹紝鍔犺浇妯″瀷鏃朵篃寮哄埗
  ///   涓嶅惎鐢?MTP锛堝嵆浣挎煇妯″瀷鏇鹃厤缃紑鍚級銆?
  /// - 寮€鍚細妯″瀷鍒楄〃鍗＄墖鏄剧ず鍚勬敮鎸?MTP 妯″瀷鐨勫紑鍏筹紝鐢ㄦ埛鍙€愪釜閰嶇疆锛?
  ///   鍔犺浇鏃舵寜 `enableMtpFeature && mtpEnabled(modelId)` 鍐冲畾鏄惁鍚敤銆?
  /// 绔晶 MTP 鎬ц兘宸敹鐩婂樊锛屾晠榛樿鍏抽棴锛屼粎楂樼鏈虹敤鎴锋寜闇€鎵撳紑娴嬭瘯銆?
  final bool enableMtpFeature;

  /// 鏄惁鍚敤 dspark 鎶曟満鍔犻€燂紝鎸夋ā鍨?id 閫愪釜寮€鍏筹紙榛樿鍏ㄥ叧锛夈€?
  /// 浠呭鐩綍澹版槑 dspark 鑽夌澶达紙config.dspark锛変笖鑽夌鏂囦欢宸蹭笅杞藉畬鏁寸殑妯″瀷
  /// 鐢熸晥鈥斺€斾笌 MTP 浜掓枼锛堝師鐢熷眰浜岄€変竴锛夛紝浜掍笉褰卞搷銆?
  final Map<String, bool> dsparkEnabledByModel;

  /// 鍏ㄥ眬 dspark 鍔熻兘鎬诲紑鍏筹紙榛樿鍏抽棴锛夈€傜敤浜庢帶鍒舵暣涓?APP 鐨?dspark 鏄惁
  /// 銆屽彲瑙佸彲鐢ㄣ€嶏細
  /// - 鍏抽棴锛堥粯璁わ級锛氭ā鍨嬪崱鐗囦笉鏄剧ず鍚勬ā鍨嬬殑 dspark 寮€鍏筹紝鍔犺浇妯″瀷鏃朵篃寮哄埗
  ///   涓嶅惎鐢紙鍗充娇鏌愭ā鍨嬫浘閰嶇疆寮€鍚級銆?
  /// - 寮€鍚細妯″瀷鍒楄〃鍗＄墖鏄剧ず澹版槑浜嗚崏绋垮ご妯″瀷鐨?dspark 寮€鍏筹紝鐢ㄦ埛鍙€愪釜
  ///   閰嶇疆锛涘姞杞芥椂鎸?`enableDsparkFeature && dsparkEnabled(modelId)` 鍐冲畾
  ///   鏄惁甯︿笂鑽夌妯″瀷銆?
  /// 绔晶 Q1_0 绛変綆姣旂壒妯″瀷涓?dspark 鏀剁泭鏈夐檺锛堥獙璇佹壒鎽婁笉鍔ㄦ潈閲嶈鍙栵紝
  /// 鍑€鍚炲悙鈮堝熀绾跨敋鑷虫洿浣庯級锛屾晠榛樿鍏抽棴锛屾寜闇€寮€鍚€?
  final bool enableDsparkFeature;

  /// 鍚姩鍚庤嚜鍔ㄥ姞杞界殑銆岄粯璁ゆā鍨嬨€峣d銆俷ull = 鏈缃€?
  /// 鐢ㄦ埛鍦ㄦā鍨嬬鐞嗛〉瀵规煇涓凡缂撳瓨妯″瀷鍕鹃€夈€岃涓洪粯璁ゃ€嶅悗鎸佷箙鍖栵紱
  /// 鍚姩杩涘叆棣栭〉鏃惰嫢璇ユā鍨嬪凡缂撳瓨鍒欒嚜鍔ㄥ姞杞斤紝淇濊瘉寮€绠卞嵆鐢ㄣ€?
  final String? defaultModelId;

  /// 宸查厤缃殑 OpenAI 鍏煎杩滅▼妯″瀷鍒楄〃锛堝彲閰嶅涓紝瀵嗛挜鏄庢枃瀛樻湰鍦帮級銆?
  final List<ApiModelConfig> apiModels;

  /// 褰撳墠婵€娲荤殑 API 妯″瀷 id銆俷ull = 鍋滅敤 API 鎺ュ叆锛堜粎鐢ㄦ湰鍦版ā鍨嬶級銆?
  /// 璺敱绛栫暐锛氭湰鍦版ā鍨嬩紭鍏堬紝浠呭綋鏈湴妯″瀷鏈姞杞?鍔犺浇澶辫触鏃舵墠璧版縺娲荤殑 API銆?
  final String? activeApiModelId;

  // ---------------------------------------------------------------
  // 鏅鸿兘浣擄紙Agent锛夐厤缃?
  // ---------------------------------------------------------------

  /// 鏅鸿兘浣撴ā寮忔€诲紑鍏炽€傞粯璁ゅ紑鍚細鏃犲伐鍏锋椂涓€杞洿绛旓紙涓庢櫘閫氳亰澶╀竴鑷达級锛?
  /// 鏈夊伐鍏疯皟鐢ㄦ椂杩涘叆宸ュ叿寰幆銆傚叧闂?= 瀹屽叏璧版櫘閫氳亰澶╄矾寰勩€?
  final bool agentEnabled;

  /// 鏄惁鍚敤銆屾柊鏅鸿兘浣撴ā寮忋€嶏紙Phase 0 璧烽噸鍐欑殑浜嬩欢婧?ReactLoopAgent锛夈€?
  /// - 寮€鍚紙榛樿锛夛細璧版柊浜嬩欢鏃ュ織 + 涓诲惊鐜紙G12 娲剧敓璇锋眰銆佸け璐ョ€戝竷銆佸彇娑堢珵璺戯級銆?
  /// - 鍏抽棴锛氬洖閫€鍒版棫 `runAgent` 閫昏緫锛堜繚鐣欏彲鍥為€€锛夈€?
  final bool useNewAgentMode;

  /// 鏅鸿兘浣撻┍鍔ㄦā鍨嬫潵婧愶細'local'锛堟湰鍦扮渚фā鍨嬶級/ 'api'锛圓PI 鎺ュ叆妯″瀷锛夈€?
  /// null = 璺熼殢榛樿璺敱锛堟湰鍦颁紭鍏堬紝API 鍏滃簳锛夈€?
  final String? agentModelSource;

  /// 鏅鸿兘浣撻┍鍔ㄦā鍨?id锛堝搴旀湰鍦版ā鍨嬬洰褰?id 鎴?API 妯″瀷閰嶇疆 id锛夈€?
  /// 涓?[agentModelSource] 鎴愬浣跨敤锛泂ource 涓?null 鏃跺拷鐣ャ€?
  final String? agentModelId;

  /// 鏅鸿兘浣撴ā寮忕殑涓婁笅鏂囬暱搴︼紙n_ctx锛夈€傜嫭绔嬩簬鏅€氳亰澶╃殑 [contextSize]锛?
  /// 宸ュ叿寰幆闇€瑕侀澶栫┖闂村绾炽€屽伐鍏疯皟鐢?+ 缁撴灉鍥炲～銆嶅巻鍙层€?
  final int agentNctx;

  /// 宸ュ叿寰幆杞涓婇檺锛?~20锛夈€傞粯璁?5锛氱渚ч€熷害鏈夐檺锛岃疆娆¤繃澶氫綋楠屽樊銆?
  final int agentMaxRounds;

  /// web_search 每回合调用上限（1~10，默认 5）。对齐 DSH 服务端工具 max_uses
  /// 语义：达到上限后 web_search 拒绝联网并返回收敛指令，杜绝反复搜索。
  final int agentMaxSearchesPerTurn;

  /// 姣忚疆鐢熸垚鐨?token 棰勭畻銆傞粯璁?512锛氳冻澶熻緭鍑轰竴娆″伐鍏疯皟鐢?JSON 鎴栦竴娈靛洖绛斻€?
  final int agentTokensPerRound;

  /// 鍗曞伐鍏锋墽琛岃秴鏃讹紙姣锛夈€傞粯璁?15s锛氶槻姝㈠伐鍏峰崱姝绘嫋浣忔暣涓惊鐜€?
  final int agentToolTimeoutMs;

  /// 鏄惁鍏佽骞惰宸ュ叿璋冪敤锛堥粯璁ゅ叧闂紱寮€鍚悗鎸?[agentMaxParallel] 鍒嗘壒骞跺彂锛夈€?
  final bool agentAllowParallelTools;

  /// 骞惰宸ュ叿骞跺彂涓婇檺锛堥粯璁?4锛涘疄闄呭啀鍙楅┍鍔ㄦā鍨嬭兘鍔涘す绱э級銆?
  final int agentMaxParallel;

  /// 鐢熸垚娓╁害锛?~2锛岄粯璁?0.7锛夈€傚伐鍏峰喅绛栧缓璁亸浣庯紝鐩寸瓟鍦烘櫙鍙亸楂樸€?
  final double agentTemperature;

  /// 瀛愪唬鐞嗗伐鍏凤紙subagent锛宻pawn/fork锛夋敞鍐屽紑鍏炽€傞粯璁ゅ紑锛?
  /// 涓嶅彉閲忓浐瀹氾紙娣卞害 鈮?2 / 瀛愪唬鐞嗗鎵规亽 never / 姣忓眰鐙珛棰勭畻锛夈€?
  final bool agentSubagentEnabled;

  /// 涓婁笅鏂囪秴闄愯嚜鍔ㄥ帇缂╋紙榛樿寮€锛涘叧闂悗瓒呴檺鐩存帴鎶ラ敊缁堟锛夈€?
  final bool agentCompactEnabled;

  /// 瓒呴暱宸ュ叿杈撳嚭婧㈠啓钀界洏锛堥粯璁ゅ紑锛涙ā鍨嬩晶鍙暀鎽樿涓庢枃浠跺畾浣嶏級銆?
  final bool agentSpillEnabled;

  /// 鑱旂綉鎼滅储宸ュ叿鎬诲紑鍏筹紙榛樿鍏抽棴锛歸eb_search 榛樿涓嶆敞鍐岋紝闇€鎵嬪姩寮€鍚級銆?
  final bool webSearchEnabled;

  /// 鑱旂綉鎼滅储 SearXNG 瀹炰緥鍦板潃锛堢敤鎴峰湪銆岃缃?鈫?API 鎺ュ叆 鈫?鑱旂綉鎼滅储銆嶅～鍐欙級銆?
  ///
  /// 榛樿鐣欑┖ = 鏈厤缃€備笉瑕侀缃换浣曚釜浜哄疄渚嬪湴鍧€锛涚┖鍦板潃鏃?provider 浼氳繑鍥?
  /// "璇峰厛鍦ㄨ缃噷濉啓鍦板潃"鐨勮瘖鏂紝鑰屼笉鏄嬁 127.0.0.1 鍘昏繛鎵嬫満鑷繁銆?
  final String webSearchSearXngBaseUrl;

  /// SearXNG 瀹炰緥鐨?API key锛堢鏈夊疄渚嬫墠闇€瑕侊紱绌?= 鏃犻渶瀵嗛挜锛夈€?
  final String? webSearchSearXngApiKey;

  /// 鍗曟 SearXNG 鎼滅储鏈€澶氳繑鍥炴潵婧愭潯鏁帮紙瀵归綈 DSH 榛樿 8锛夈€?
  final int webSearchSearXngMaxResults;

  /// 鍗曟 SearXNG 鎼滅储瓒呮椂姣銆?
  ///
  /// 榛樿 30s锛歋earXNG 鑱氬悎澶氬紩鎿庢湰韬氨鎱紙涓€鍙拌嚜寤哄疄渚嬭蛋鍏ㄥ紩鎿庡疄娴?21s锛屽鏁?
  /// 鏃堕棿鑰楀湪鍏惰闂笉鍒扮殑寮曟搸涓婏級锛屾棫鐨?15s 榛樿鍊间細璁╄繖绫诲疄渚?*姣忔閮藉繀鐒惰秴鏃?*锛?
  /// 鐢?[webSearchSearXngEngines] 鍙暀鍙揪寮曟搸鍚庡彲闄嶅埌绉掔骇銆?
  final int webSearchSearXngTimeoutMs;

  /// SearXNG 鎼滅储璇█锛堝 "zh-CN"锛夛紱绌?= 涓嶆寚瀹氥€?
  final String? webSearchSearXngLanguage;

  /// SearXNG 鎼滅储鍒嗙被锛堝 "general","news"锛夛紱绌?= 涓嶆寚瀹氥€?
  final String? webSearchSearXngCategories;

  /// SearXNG 寮曟搸鐧藉悕鍗曪紙閫楀彿鍒嗛殧锛屽 `bing,sogou`锛夈€?
  ///
  /// 榛樿鐣欑┖ = 鐢卞疄渚嬪喅瀹氱敤鍝簺寮曟搸銆傚綋瀹炰緥涓婂瓨鍦ㄨ闂笉鍒扮殑寮曟搸鏃讹紝鎶婂畠浠庣櫧鍚嶅崟
  /// 閲屽幓鎺夊彲鎶婃悳绱粠浜屽崄绉掔骇闄嶅埌绉掔骇銆傝嫢鐧藉悕鍗曢噷鏈夎瀹炰緥涓嶈璇嗙殑寮曟搸锛孲earXNG 浼?
  /// 鎶?400锛宲rovider 浼氳嚜鍔ㄥ幓鎺夎鍙傛暟閲嶈瘯涓€娆★紙瑙?SearXNGSearchProvider.search锛夈€?
  final String? webSearchSearXngEngines;

  /// shell 鎵ц宸ュ叿寮€鍏筹紙榛樿寮€鍚細绔晶鑳藉姏鍚戝己鎵╁睍锛屼笉鑷垜璁鹃檺锛?
  /// 鐢ㄦ埛鍙湪璁剧疆涓叧闂級銆?
  final bool agentShellEnabled;

  /// python_exec 宸ュ叿寮€鍏筹紙榛樿寮€鍚細宓屽叆寮?CPython锛岃剼鏈兘鍔涘悜寮烘墿灞曪紱
  /// 鏈泦鎴?Chaquopy 鏃跺伐鍏蜂紭闆呴檷绾т负鏄庣‘閿欒锛夈€?
  final bool agentPythonEnabled;

  /// 娌欑瀹屾暣鏂囦欢绯荤粺鎺堟潈锛堝鐓?DSH danger-full-access锛夛細寮€鍚悗鍏佽
  /// 鏅鸿兘浣撶粡鐢ㄦ埛閫愭瀹℃壒璁块棶鍏叡鐩綍/瀹屾暣鏂囦欢绯荤粺锛堜緷璧?
  /// MANAGE_EXTERNAL_STORAGE / All-Files-Access锛夈€?
  final bool agentFullFileAccess;

  /// 闀挎湡璁板繂寮€鍏筹紙memory_set/memory_get锛夈€傞粯璁?*鍏抽棴**锛氳法浼氳瘽鎸佷箙鍖?
  /// 鐨勮蹇嗗彲鑳界Н绱伓鍙戦敊璇紙涓嶅悓妯″瀷/鎯呭喌璇啓锛夛紝寮€鍚悗鐢辩敤鎴锋樉寮忛厤缃€?
  final bool agentMemoryEnabled;

  /// 鎺ㄧ悊寮曟搸锛氭槸鍚﹂粯璁ゅ姞杞借瑙夋姇褰卞櫒锛坢mproj锛夈€傞粯璁?true锛堥拡瀵规湁鎶曞奖鍣ㄧ殑
  /// 妯″瀷锛夛紱鍏抽棴鍚庤瑙夋ā鍨嬩粎鏂囨湰鎺ㄧ悊锛屼笉鍔犺浇鎶曞奖鍣ㄣ€?
  final bool autoLoadMmproj;

  /// 鎺ㄧ悊寮曟搸锛欸PU/CPU 鍗犵敤鐜囩洃鎺у憟鐜帮紙妯″瀷鐘舵€佹爮搴曢儴鍙岃壊绾匡級銆傞粯璁ゅ紑鍚€?
  final bool showResourceMonitor;

  /// 鍗犵敤鐜囬噰鏍峰懆鏈燂紙绉掞級锛?~30銆傞粯璁?0锛氫粎鎺ㄧ悊鏃朵簨浠堕┍鍔ㄩ噰鏍凤紙绌洪棽涓嶉噰鏍凤紝
  /// 鐪佺數锛夛紱>0锛氭瘡闅?N 绉掑懆鏈熸€ч噰鏍凤紙绌洪棽涔熸洿鏂扮嚎鏉★級銆?
  final int resourceSampleIntervalSec;
  /// OOM 鍐呭瓨瀹堝崼鎬诲紑鍏筹紙璁剧疆鈫掓帹鐞嗗紩鎿庘啋鍐呭瓨瀹堝崼锛夈€傞粯璁ゅ紑鍚細鍔犺浇鍓嶉妫€
  /// 銆屾ā鍨嬩綋绉?+ 棰勬浣欓噺銆嶆槸鍚﹁秴鍑哄彲鐢ㄥ唴瀛橈紝瓒呭嚭鍒欐嫆缁濆姞杞斤紝闃叉 UMA 鎵嬫満
  /// 鏁存満纭鏈恒€傚叧闂?= 瀹屽叏璺宠繃瀹堝崼鎷掔粷锛堥珮绾х敤鎴锋帓闅滅敤锛屾湁姝绘満椋庨櫓锛夈€?
  final bool oomGuardEnabled;

  /// OOM 棰勬浣欓噺锛圡B锛岄粯璁?768锛夈€傚姞杞藉墠 MemAvailable 鎵ｉ櫎璇ヤ綑閲忓悗鍐嶄笌
  /// 妯″瀷浣撶Н姣旇緝锛涜皟灏忔洿瀹规槗鏀捐繃鎺ヨ繎鏋侀檺鐨勫ぇ妯″瀷锛岃皟澶ф洿淇濆畧銆?
  final int oomPreHeadroomMb;

  /// OOM 鍔犺浇鍚庝綑閲忥紙MB锛岄粯璁?1536锛夈€傚姞杞藉畬鎴愬悗 KV cache / 鍥捐绠楃紦鍐茬殑
  /// 鍐呭瓨棰勭畻 = MemAvailable - 璇ヤ綑閲忥紱璋冨皬鍙粰 KV 鏇村ぇ绌洪棿锛岃皟澶ф洿淇濆畧銆?
  final int oomPostHeadroomMb;

  /// 鎸夋ā鍨嬪惎鐢ㄧ殑宸ュ叿娓呭崟锛歚{modelId: [toolName]}`銆傜┖ = 浣跨敤璇ユā鍨?
  /// 鐩綍澹版槑鐨勯粯璁ゅ伐鍏烽泦锛坅gentDefaults.enabledTools锛夈€?
  final Map<String, List<String>> agentToolsByModel;

  /// 鎸夋ā鍨嬬殑 agent 閰嶇疆瑕嗙洊锛歚{modelId: {maxRounds, tokensPerRound, nctx}}`銆?
  /// 瑕嗙洊鍏ㄥ眬榛樿鍊硷紙妯″瀷鐩綍 agentDefaults 鍚堝苟鍒扮敤鎴疯缃級銆?
  final Map<String, Map<String, dynamic>> agentByModel;

  // ---- 鑱旂綉鎼滅储榛樿鍊硷紙淇濇寔涓€э細涓嶉缃换浣曚釜浜哄疄渚嬶級----
  // 鍦板潃榛樿鐣欑┖ = 鏈厤缃€傜湡鏈轰笂娌℃湁鍙敤瀹炰緥鏃讹紝provider 浼氱粰鍑?璇峰厛鍦?
  // 璁剧疆 鈫?鑱旂綉鎼滅储濉啓鍦板潃"鐨勬槑纭瘖鏂紝鑰屼笉鏄嬁 127.0.0.1 鍘昏繛鎵嬫満鑷繁銆?
  static const String kDefaultSearXngBaseUrl = '';

  // 寮曟搸鐧藉悕鍗曢粯璁ょ暀绌?= 鐢卞疄渚嬪喅瀹氥€傚疄渚嬩笂鏈変笉鍙揪寮曟搸锛堝澧欏唴瀹炰緥鎸傜潃
  // google cse / duckduckgo锛夋椂锛岀敤鎴疯嚜琛屽～鍐欏彲杈惧紩鎿庡彲鏄捐憲鎻愰€?
  // 锛堝疄娴嬫煇瀹炰緥锛氬叏寮曟搸 21s 鈫?鎸囧畾 2 涓彲杈惧紩鎿?2.5s锛夈€?
  static const String kDefaultSearXngEngines = '';

  // 瓒呮椂 30s锛氬疄渚嬭仛鍚堝寮曟搸鏈韩灏辫鍗佸嚑鍒颁簩鍗佸嚑绉掞紝15s 浼氱ǔ瀹氳鏉€銆?
  static const int kDefaultSearXngTimeoutMs = 30000;

  const InferenceSettings({
    // 榛樿寮€鍚?GPU锛氫笌 gpuLayers=100 鍏ㄩ噺鍗歌浇涓€鑷达紱鍦?settingsProvider
    // 寮傛 _load() 瀹屾垚鍓嶏紝UI/鍔犺浇閫昏緫鑻ヨ鍙栭粯璁ゅ€硷紝浠嶅簲璧?GPU 璺緞锛?
    // 閬垮厤鍚姩鍚庨娆″姞杞芥ā鍨嬫剰澶栬惤鍒?CPU銆?
    this.enableGpu = true,
    this.gpuLayers = 100,
    this.contextSize = 4096,
    this.enableThinking = false,
    this.gpuBackend = 'auto',
    Map<String, bool>? mtpEnabledByModel,
    this.enableMtpFeature = false,
    Map<String, bool>? dsparkEnabledByModel,
    this.enableDsparkFeature = false,
    this.defaultModelId,
    List<ApiModelConfig>? apiModels,
    this.activeApiModelId,
    // ---- 鏅鸿兘浣擄紙Agent锛?---
    this.agentEnabled = true,
    this.useNewAgentMode = true,
    this.agentModelSource,
    this.agentModelId,
    this.agentNctx = 8192,
    // 2026-09-28 调大：5 步/512 token 对真实任务太小（多步任务必撞上限、
    // 思考型模型 512 连工具调用都写不完被截断）。存量等于旧默认的值在
    // fromJson 一次性迁移到新默认。
    this.agentMaxRounds = 12,
    this.agentMaxSearchesPerTurn = 5,
    this.agentTokensPerRound = 1024,
    this.agentToolTimeoutMs = 15000,
    this.agentAllowParallelTools = false,
    this.agentMaxParallel = 4,
    this.agentTemperature = 0.7,
    this.agentSubagentEnabled = true,
    this.agentCompactEnabled = true,
    this.agentSpillEnabled = true,
    this.webSearchEnabled = false,
    this.webSearchSearXngBaseUrl = kDefaultSearXngBaseUrl,
    this.webSearchSearXngApiKey,
    this.webSearchSearXngMaxResults = 8,
    this.webSearchSearXngTimeoutMs = kDefaultSearXngTimeoutMs,
    this.webSearchSearXngLanguage,
    this.webSearchSearXngCategories,
    this.webSearchSearXngEngines = kDefaultSearXngEngines,
    this.agentShellEnabled = true,
    this.agentPythonEnabled = true,
    this.agentFullFileAccess = false,
    // 闀挎湡璁板繂榛樿鍏抽棴锛堣法浼氳瘽璁板繂鍙兘绉疮鍋跺彂閿欒锛岄粯璁や笉鍚敤锛夈€?
    this.agentMemoryEnabled = false,
    // ---- 鎺ㄧ悊寮曟搸 ----
    this.autoLoadMmproj = true,
    this.showResourceMonitor = true,
    this.resourceSampleIntervalSec = 1,
    // OOM 鍐呭瓨瀹堝崼榛樿寮€鍚紝浣欓噺榛樿涓庡師鐢熷眰甯搁噺涓€鑷达紙768 / 1536 MB锛夈€?
    this.oomGuardEnabled = true,
    this.oomPreHeadroomMb = 768,
    this.oomPostHeadroomMb = 1536,
    Map<String, List<String>>? agentToolsByModel,
    Map<String, Map<String, dynamic>>? agentByModel,
  })  : mtpEnabledByModel = mtpEnabledByModel ?? const {},
        dsparkEnabledByModel = dsparkEnabledByModel ?? const {},
        apiModels = apiModels ?? const [],
        agentToolsByModel = agentToolsByModel ?? const {},
        agentByModel = agentByModel ?? const {};

  /// 渚挎嵎璇诲彇锛氭煇涓ā鍨嬫槸鍚﹀惎鐢?MTP锛堟湭閰嶇疆瑙嗕负鍏抽棴锛夈€?
  bool mtpEnabled(String modelId) => mtpEnabledByModel[modelId] ?? false;

  /// 渚挎嵎璇诲彇锛氭煇涓ā鍨嬫槸鍚﹀惎鐢?dspark锛堟湭閰嶇疆瑙嗕负鍏抽棴锛夈€?
  bool dsparkEnabled(String modelId) => dsparkEnabledByModel[modelId] ?? false;

  /// 渚挎嵎璇诲彇锛氭煇涓ā鍨嬪惎鐢ㄧ殑宸ュ叿娓呭崟銆傜┖鍒楄〃 = 璺熼殢璇ユā鍨嬬洰褰曞０鏄庣殑
  /// agentDefaults.enabledTools锛堢洰褰曞悎骞堕€昏緫鍦?agent 鎺ュ叆灞傦級銆?
  List<String> agentToolsFor(String modelId) =>
      agentToolsByModel[modelId] ?? const [];

  /// 渚挎嵎璇诲彇锛氭煇涓ā鍨嬬殑 agent 閰嶇疆瑕嗙洊锛堟湭閰嶇疆杩斿洖 null锛夈€?
  Map<String, dynamic>? agentConfigFor(String modelId) =>
      agentByModel[modelId];

  /// 渚挎嵎璇诲彇锛氬綋鍓嶆縺娲荤殑 API 妯″瀷閰嶇疆锛涙湭婵€娲?涓嶅瓨鍦ㄨ繑鍥?null銆?
  ApiModelConfig? activeApiModel() {
    if (activeApiModelId == null) return null;
    for (final cfg in apiModels) {
      if (cfg.id == activeApiModelId) return cfg;
    }
    return null;
  }

  InferenceSettings copyWith(
      {bool? enableGpu,
      int? gpuLayers,
      int? contextSize,
      bool? enableThinking,
      String? gpuBackend,
      Map<String, bool>? mtpEnabledByModel,
      bool? enableMtpFeature,
      Map<String, bool>? dsparkEnabledByModel,
      bool? enableDsparkFeature,
      String? defaultModelId,
      // defaultModelId 涓哄彲绌?String锛屾棤娉曠敤 `?? this` 鍖哄垎銆屾湭浼犮€嶄笌銆屾竻绌恒€嶏紝
      // 鏁呭鍔犳樉寮忔竻绌烘爣璁帮紝渚涘彇娑堥粯璁ゆā鍨嬫椂浣跨敤銆?
      bool clearDefaultModel = false,
      List<ApiModelConfig>? apiModels,
      String? activeApiModelId,
      // activeApiModelId 鍚屾牱鍙┖锛岄渶鏄惧紡鏍囪浠ュ尯鍒嗐€屾湭浼犮€嶄笌銆屽仠鐢ㄣ€嶃€?
      bool clearActiveApiModel = false,
      // ---- 鏅鸿兘浣擄紙Agent锛?---
      bool? agentEnabled,
      bool? useNewAgentMode,
      String? agentModelSource,
      String? agentModelId,
      // agentModelSource/agentModelId 鍧囧彲绌猴紝闇€鏄惧紡鏍囪鍖哄垎銆屾湭浼犮€嶄笌銆屾竻绌恒€嶃€?
      bool clearAgentModel = false,
      int? agentNctx,
      int? agentMaxRounds,
      int? agentMaxSearchesPerTurn,
      int? agentTokensPerRound,
      int? agentToolTimeoutMs,
      bool? agentAllowParallelTools,
      int? agentMaxParallel,
      double? agentTemperature,
      bool? agentSubagentEnabled,
      bool? agentCompactEnabled,
      bool? agentSpillEnabled,
      bool? webSearchEnabled,
      String? webSearchSearXngBaseUrl,
      String? webSearchSearXngApiKey,
      int? webSearchSearXngMaxResults,
      int? webSearchSearXngTimeoutMs,
      String? webSearchSearXngLanguage,
      String? webSearchSearXngCategories,
      String? webSearchSearXngEngines,
      bool? agentShellEnabled,
      bool? agentPythonEnabled,
      bool? agentFullFileAccess,
      bool? agentMemoryEnabled,
      // ---- 鎺ㄧ悊寮曟搸 ----
      bool? autoLoadMmproj,
      bool? showResourceMonitor,
      int? resourceSampleIntervalSec,
      bool? oomGuardEnabled,
      int? oomPreHeadroomMb,
      int? oomPostHeadroomMb,
      Map<String, List<String>>? agentToolsByModel,
      Map<String, Map<String, dynamic>>? agentByModel}) {
    return InferenceSettings(
      enableGpu: enableGpu ?? this.enableGpu,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      enableThinking: enableThinking ?? this.enableThinking,
      gpuBackend: gpuBackend ?? this.gpuBackend,
      mtpEnabledByModel: mtpEnabledByModel ?? this.mtpEnabledByModel,
      enableMtpFeature: enableMtpFeature ?? this.enableMtpFeature,
      dsparkEnabledByModel:
          dsparkEnabledByModel ?? this.dsparkEnabledByModel,
      enableDsparkFeature: enableDsparkFeature ?? this.enableDsparkFeature,
      defaultModelId: clearDefaultModel
          ? null
          : defaultModelId ?? this.defaultModelId,
      apiModels: apiModels ?? this.apiModels,
      activeApiModelId: clearActiveApiModel
          ? null
          : activeApiModelId ?? this.activeApiModelId,
      agentEnabled: agentEnabled ?? this.agentEnabled,
      useNewAgentMode: useNewAgentMode ?? this.useNewAgentMode,
      agentModelSource: clearAgentModel
          ? null
          : agentModelSource ?? this.agentModelSource,
      agentModelId: clearAgentModel
          ? null
          : agentModelId ?? this.agentModelId,
      agentNctx: agentNctx ?? this.agentNctx,
      agentMaxRounds: agentMaxRounds ?? this.agentMaxRounds,
      agentMaxSearchesPerTurn:
          agentMaxSearchesPerTurn ?? this.agentMaxSearchesPerTurn,
      agentTokensPerRound: agentTokensPerRound ?? this.agentTokensPerRound,
      agentToolTimeoutMs: agentToolTimeoutMs ?? this.agentToolTimeoutMs,
      agentAllowParallelTools:
          agentAllowParallelTools ?? this.agentAllowParallelTools,
      agentMaxParallel: agentMaxParallel ?? this.agentMaxParallel,
      agentTemperature: agentTemperature ?? this.agentTemperature,
      agentSubagentEnabled: agentSubagentEnabled ?? this.agentSubagentEnabled,
      agentCompactEnabled: agentCompactEnabled ?? this.agentCompactEnabled,
      agentSpillEnabled: agentSpillEnabled ?? this.agentSpillEnabled,
      webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      webSearchSearXngBaseUrl:
          webSearchSearXngBaseUrl ?? this.webSearchSearXngBaseUrl,
      webSearchSearXngApiKey:
          webSearchSearXngApiKey ?? this.webSearchSearXngApiKey,
      webSearchSearXngMaxResults:
          webSearchSearXngMaxResults ?? this.webSearchSearXngMaxResults,
      webSearchSearXngTimeoutMs:
          webSearchSearXngTimeoutMs ?? this.webSearchSearXngTimeoutMs,
      webSearchSearXngLanguage:
          webSearchSearXngLanguage ?? this.webSearchSearXngLanguage,
      webSearchSearXngCategories:
          webSearchSearXngCategories ?? this.webSearchSearXngCategories,
      webSearchSearXngEngines:
          webSearchSearXngEngines ?? this.webSearchSearXngEngines,
      agentShellEnabled: agentShellEnabled ?? this.agentShellEnabled,
      agentPythonEnabled: agentPythonEnabled ?? this.agentPythonEnabled,
      agentFullFileAccess:
          agentFullFileAccess ?? this.agentFullFileAccess,
      agentMemoryEnabled: agentMemoryEnabled ?? this.agentMemoryEnabled,
      autoLoadMmproj: autoLoadMmproj ?? this.autoLoadMmproj,
      showResourceMonitor: showResourceMonitor ?? this.showResourceMonitor,
      resourceSampleIntervalSec:
          resourceSampleIntervalSec ?? this.resourceSampleIntervalSec,
      oomGuardEnabled: oomGuardEnabled ?? this.oomGuardEnabled,
      oomPreHeadroomMb: oomPreHeadroomMb ?? this.oomPreHeadroomMb,
      oomPostHeadroomMb: oomPostHeadroomMb ?? this.oomPostHeadroomMb,
      agentToolsByModel: agentToolsByModel ?? this.agentToolsByModel,
      agentByModel: agentByModel ?? this.agentByModel,
    );
  }

  Map<String, dynamic> toJson() => {
        'enableGpu': enableGpu,
        'gpuLayers': gpuLayers,
        'contextSize': contextSize,
        'enableThinking': enableThinking,
        'gpuBackend': gpuBackend,
        'mtpEnabledByModel': mtpEnabledByModel,
        'enableMtpFeature': enableMtpFeature,
        'dsparkEnabledByModel': dsparkEnabledByModel,
        'enableDsparkFeature': enableDsparkFeature,
        'defaultModelId': defaultModelId,
        'apiModels': apiModels.map((m) => m.toJson()).toList(),
        'activeApiModelId': activeApiModelId,
        // ---- 鏅鸿兘浣擄紙Agent锛?---
        'agentEnabled': agentEnabled,
        'useNewAgentMode': useNewAgentMode,
        'agentModelSource': agentModelSource,
        'agentModelId': agentModelId,
        'agentNctx': agentNctx,
        'agentMaxRounds': agentMaxRounds,
        'agentMaxSearchesPerTurn': agentMaxSearchesPerTurn,
        'agentTokensPerRound': agentTokensPerRound,
        'agentToolTimeoutMs': agentToolTimeoutMs,
        'agentAllowParallelTools': agentAllowParallelTools,
        'agentMaxParallel': agentMaxParallel,
        'agentTemperature': agentTemperature,
        'agentSubagentEnabled': agentSubagentEnabled,
        'agentCompactEnabled': agentCompactEnabled,
        'agentSpillEnabled': agentSpillEnabled,
        'webSearchEnabled': webSearchEnabled,
        'webSearchSearXngBaseUrl': webSearchSearXngBaseUrl,
        'webSearchSearXngApiKey': webSearchSearXngApiKey,
        'webSearchSearXngMaxResults': webSearchSearXngMaxResults,
        'webSearchSearXngTimeoutMs': webSearchSearXngTimeoutMs,
        'webSearchSearXngLanguage': webSearchSearXngLanguage,
        'webSearchSearXngCategories': webSearchSearXngCategories,
        'webSearchSearXngEngines': webSearchSearXngEngines,
        'agentShellEnabled': agentShellEnabled,
        // 淇閬楃暀锛歱ython_exec 涓庡畬鏁存枃浠惰闂紑鍏虫鍓嶆湭鍐欏叆 toJson锛?
        // 淇濆瓨鍚庤鍥炰細闈欓粯涓㈤厤缃紙榛樿鍊煎厹搴曪級銆?
        'agentPythonEnabled': agentPythonEnabled,
        'agentFullFileAccess': agentFullFileAccess,
        'agentMemoryEnabled': agentMemoryEnabled,
        // ---- 鎺ㄧ悊寮曟搸 ----
        'autoLoadMmproj': autoLoadMmproj,
        'showResourceMonitor': showResourceMonitor,
        'resourceSampleIntervalSec': resourceSampleIntervalSec,
        'oomGuardEnabled': oomGuardEnabled,
        'oomPreHeadroomMb': oomPreHeadroomMb,
        'oomPostHeadroomMb': oomPostHeadroomMb,
        'agentToolsByModel': agentToolsByModel,
        'agentByModel': agentByModel,
      };

  factory InferenceSettings.fromJson(Map<String, dynamic> json) {
    return InferenceSettings(
      // 缂虹渷/鏃ф枃浠舵湭瀛樿瀛楁鏃堕粯璁ゅ紑鍚?GPU锛歛uto 鍚庣浼氬湪鏃?GPU 鏃惰嚜鍔?
      // 鍥炶惤 CPU锛孷0.1.5 宸查獙璇?Adreno 825 OpenCL/Vulkan 鍧囨甯搞€?
      enableGpu: json['enableGpu'] as bool? ?? true,
      gpuLayers: (json['gpuLayers'] as num?)?.toInt() ?? 100,
      contextSize: (json['contextSize'] as num?)?.toInt() ?? 4096,
      enableThinking: json['enableThinking'] as bool? ?? false,
      gpuBackend: json['gpuBackend'] as String? ?? 'auto',
      // 鏃х増鏈瓨鐨勬槸鍏ㄥ眬 bool enableMtp锛氳嫢璇诲埌瀹冿紝鍒欐槧灏勪负鎵€鏈夋敮鎸佹ā鍨嬬殑
      // 榛樿鍊硷紝淇濊瘉鑰侀厤缃笉涓€?
      mtpEnabledByModel: _migrateLegacyMtp(json),
      // 鍏ㄥ眬 MTP 寮€鍏筹細鏃ч厤缃棤姝ゅ瓧娈垫椂榛樿鍏抽棴锛堝悜鍚庡吋瀹癸級銆?
      enableMtpFeature: json['enableMtpFeature'] as bool? ?? false,
      // dspark锛氭寜妯″瀷 map + 鍏ㄥ眬寮€鍏筹紝鏃ч厤缃棤姝ゅ瓧娈垫椂榛樿鍏ㄥ叧锛堝悜鍚庡吋瀹癸級銆?
      dsparkEnabledByModel: _parseBoolMap(json['dsparkEnabledByModel']),
      enableDsparkFeature: json['enableDsparkFeature'] as bool? ?? false,
      defaultModelId: json['defaultModelId'] as String?,
      // 鏃ч厤缃己杩欎袱涓瓧娈垫椂榛樿绌哄垪琛?+ 鍋滅敤锛屽悜鍚庡吋瀹广€?
      apiModels: _parseApiModels(json['apiModels']),
      activeApiModelId: json['activeApiModelId'] as String?,
      // 鏅鸿兘浣擄紙Agent锛夛細鏃ч厤缃己瀛楁鏃剁敤榛樿鍊硷紝鍚戝悗鍏煎銆?
      agentEnabled: json['agentEnabled'] as bool? ?? true,
      // 鏃ч厤缃棤姝ゅ瓧娈垫椂榛樿寮€鍚柊鏅鸿兘浣撴ā寮忥紙鍚戝悗鍏煎锛夈€?
      useNewAgentMode: json['useNewAgentMode'] as bool? ?? true,
      agentModelSource: json['agentModelSource'] as String?,
      agentModelId: json['agentModelId'] as String?,
      agentNctx: (json['agentNctx'] as num?)?.toInt() ?? 8192,
      agentMaxRounds:
          _migrateOldDefault((json['agentMaxRounds'] as num?)?.toInt(),
              oldDefault: 5, newDefault: 12),
      agentMaxSearchesPerTurn:
          (json['agentMaxSearchesPerTurn'] as num?)?.toInt() ?? 5,
      agentTokensPerRound: _migrateOldDefault(
          (json['agentTokensPerRound'] as num?)?.toInt(),
          oldDefault: 512,
          newDefault: 1024),
      agentToolTimeoutMs:
          (json['agentToolTimeoutMs'] as num?)?.toInt() ?? 15000,
      agentAllowParallelTools:
          json['agentAllowParallelTools'] as bool? ?? false,
      agentMaxParallel: json['agentMaxParallel'] as int? ?? 4,
      agentTemperature: (json['agentTemperature'] as num?)?.toDouble() ?? 0.7,
      agentSubagentEnabled: json['agentSubagentEnabled'] as bool? ?? true,
      agentCompactEnabled: json['agentCompactEnabled'] as bool? ?? true,
      agentSpillEnabled: json['agentSpillEnabled'] as bool? ?? true,
      webSearchEnabled: json['webSearchEnabled'] as bool? ?? false,
      // 鑱旂綉鎼滅储 SearXNG 閰嶇疆锛氭棫閰嶇疆缂哄瓧娈垫椂鐢ㄩ粯璁ゅ€硷紙鍚戝悗鍏煎锛夈€?
      // 绌哄湴鍧€ = 鏈厤缃紝姝ゆ椂鑱旂綉鎼滅储宸ュ叿浼氱粰鍑?璇峰厛鍦ㄨ缃噷濉湴鍧€"鐨勮瘖鏂€?
      webSearchSearXngBaseUrl:
          json['webSearchSearXngBaseUrl'] as String? ?? kDefaultSearXngBaseUrl,
      webSearchSearXngApiKey: json['webSearchSearXngApiKey'] as String?,
      webSearchSearXngMaxResults:
          (json['webSearchSearXngMaxResults'] as num?)?.toInt() ?? 8,
      webSearchSearXngTimeoutMs:
          (json['webSearchSearXngTimeoutMs'] as num?)?.toInt() ??
              kDefaultSearXngTimeoutMs,
      webSearchSearXngLanguage: json['webSearchSearXngLanguage'] as String?,
      webSearchSearXngCategories:
          json['webSearchSearXngCategories'] as String?,
      webSearchSearXngEngines:
          json['webSearchSearXngEngines'] as String? ?? kDefaultSearXngEngines,
      agentShellEnabled: json['agentShellEnabled'] as bool? ?? true,
      agentPythonEnabled: json['agentPythonEnabled'] as bool? ?? true,
      agentFullFileAccess: json['agentFullFileAccess'] as bool? ?? false,
      // 闀挎湡璁板繂榛樿鍏抽棴锛堟棫閰嶇疆缂哄瓧娈垫椂鍚戝悗鍏煎锛夈€?
      agentMemoryEnabled: json['agentMemoryEnabled'] as bool? ?? false,
      // 鎺ㄧ悊寮曟搸鎵╁睍锛氭棫閰嶇疆缂哄瓧娈垫椂鐢ㄩ粯璁ゅ€硷紙鎶曞奖鍣ㄩ粯璁ゅ姞杞姐€佺洃鎺ч粯璁ゅ紑鍚級銆?
      autoLoadMmproj: json['autoLoadMmproj'] as bool? ?? true,
      showResourceMonitor: json['showResourceMonitor'] as bool? ?? true,
      resourceSampleIntervalSec:
          (json['resourceSampleIntervalSec'] as num?)?.toInt() ?? 1,
      // OOM 鍐呭瓨瀹堝崼锛氭棫閰嶇疆缂哄瓧娈垫椂榛樿寮€鍚?+ 鍘熺敓灞傞粯璁や綑閲忥紙鍚戝悗鍏煎锛夈€?
      oomGuardEnabled: json['oomGuardEnabled'] as bool? ?? true,
      oomPreHeadroomMb: (json['oomPreHeadroomMb'] as num?)?.toInt() ?? 768,
      oomPostHeadroomMb: (json['oomPostHeadroomMb'] as num?)?.toInt() ?? 1536,
      agentToolsByModel: _parseAgentTools(json['agentToolsByModel']),
      agentByModel: _parseAgentByModel(json['agentByModel']),
    );
  }

  /// 瑙ｆ瀽鎸夋ā鍨嬪伐鍏锋竻鍗曪細`{modelId: [toolName]}`銆傛牸寮忛潪娉曟椂杩斿洖绌?map锛堜笉宕╋級銆?
  static Map<String, List<String>> _parseAgentTools(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    raw.forEach((k, v) {
      if (v is List) {
        result[k.toString()] =
            v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
    });
    return result;
  }

  /// 瑙ｆ瀽鎸夋ā鍨?agent 閰嶇疆锛歚{modelId: {maxRounds, tokensPerRound, nctx}}`銆?
  /// 鏍煎紡闈炴硶鏃惰繑鍥炵┖ map锛堜笉宕╋級銆?
  static Map<String, Map<String, dynamic>> _parseAgentByModel(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, Map<String, dynamic>>{};
    raw.forEach((k, v) {
      if (v is Map) {
        result[k.toString()] = Map<String, dynamic>.from(v);
      }
    });
    return result;
  }

  /// 瑙ｆ瀽 API 妯″瀷鍒楄〃锛涚己瀛楁/鏍煎紡闈炴硶鏃惰繑鍥炵┖鍒楄〃锛堜笉宕╋級銆?
  static List<ApiModelConfig> _parseApiModels(Object? raw) {
    if (raw is! List) return const [];
    final list = <ApiModelConfig>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        list.add(ApiModelConfig.fromJson(e));
      } else if (e is Map) {
        list.add(ApiModelConfig.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return list;
  }

  /// 旧默认值一次性迁移：存量设置里等于旧默认的值抬到新默认（幂等）。
  ///
  /// 用户显式设置过的非默认值不动；旧默认值与"从未改过"不可区分，
  /// 一并抬升（2026-09-28 智能体预算调大：maxRounds 5→12、tokens 512→1024）。
  static int _migrateOldDefault(int? stored,
      {required int oldDefault, required int newDefault}) {
    if (stored == null) return newDefault;
    return stored == oldDefault ? newDefault : stored;
  }

  /// 兼容旧配置：旧字段 `enableMtp`（全局 bool）→ 新的按模型 map。
  ///
  /// 鍏抽敭淇锛氭枃浠堕噷鑻ュ凡瀛樺湪 `mtpEnabledByModel`锛堝綋鍓嶇増鏈爣鍑嗘牸寮忥級锛?
  /// **蹇呴』鍘熸牱閲囩敤**锛屼笉鑳藉洜涓虹己灏戦《灞?`enableMtp` 瀛楁灏辨暣浣撲涪寮冣€斺€?
  /// 鍚﹀垯姣忔 reload 閮戒細鎶婄敤鎴锋寜妯″瀷寮€鍚殑 MTP 寮€鍏虫竻绌猴紝瀵艰嚧 MTP 姘歌繙涓嶇敓鏁堛€?
  /// 浠呭綋 `mtpEnabledByModel` 缂哄け锛堣€佺増鏈彧鏈夊叏灞€ `enableMtp:true`锛夋椂锛?
  /// 鍥犳棤娉曞畾浣嶅叿浣撴ā鍨嬭€屼繚鎸侀粯璁ゅ叏鍏筹紝鐢辩敤鎴烽噸鏂版寜妯″瀷寮€鍚€?
  /// 瑙ｆ瀽鎸夋ā鍨?bool map锛堝 dsparkEnabledByModel锛夛紱鏍煎紡闈炴硶鏃惰繑鍥炵┖ map銆?
  static Map<String, bool> _parseBoolMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v as bool? ?? false));
  }

  static Map<String, bool> _migrateLegacyMtp(Map<String, dynamic> json) {
    final map = json['mtpEnabledByModel'] as Map<String, dynamic>?;
    if (map != null) {
      return map.map((k, v) => MapEntry(k, v as bool? ?? false));
    }
    // 浠呮湁鏃х増鍏ㄥ眬 enableMtp 鏃朵繚鎸侀粯璁ゅ叏鍏筹細鏃犳硶瀹氫綅鍏蜂綋妯″瀷锛堜笉杩佺Щ涓哄紑锛?
    // 瑙?AGENTS.md 绾﹀畾锛夛紝鐢辩敤鎴峰湪妯″瀷鍒楄〃閲嶆柊閫愪釜寮€鍚€?
    return const {};
  }
}

/// 鍩轰簬鏈湴 JSON 鏂囦欢鐨勮交閲忚缃寔涔呭寲锛堜笉寮曞叆棰濆渚濊禆锛屽鐢?path_provider锛夈€?
///
/// 鏂囦欢浣嶄簬搴旂敤鏂囨。鐩綍涓嬬殑 `inference_settings.json`銆?
class SettingsService {
  static const _fileName = 'inference_settings.json';

  Future<String> _resolvePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _fileName);
  }

  /// 璇诲彇璁剧疆锛涙枃浠朵笉瀛樺湪鎴栨崯鍧忔椂杩斿洖榛樿鍊笺€?
  Future<InferenceSettings> load() async {
    try {
      final path = await _resolvePath();
      final file = File(path);
      if (!await file.exists()) return const InferenceSettings();
      final content = await file.readAsString();
      if (content.trim().isEmpty) return const InferenceSettings();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InferenceSettings.fromJson(json);
    } catch (e) {
      // 浠讳綍瑙ｆ瀽閿欒閮藉洖钀藉埌榛樿鍊硷紝閬垮厤褰卞搷涓绘祦绋嬨€?
      return const InferenceSettings();
    }
  }

  /// 鍐欏叆璁剧疆銆傚け璐ユ椂鎶涘嚭寮傚父鐢辫皟鐢ㄦ柟澶勭悊銆?
  ///
  /// 鍘熷瓙鍐欏叆锛氬厛鍐?`.tmp` 鍐?rename銆傛鍓嶇洿鎺?writeAsString锛屽穿婧?鏂數鏃?
  /// 鍙兘鐣欎笅鍗婃埅 JSON鈥斺€攍oad 鍏ㄩ儴鍥炶惤榛樿鍊硷紝鐢ㄦ埛閰嶇疆闈欓粯涓㈠け銆俽ename 鍦?
  /// 鍚岀洰褰曚笂鏄師瀛愭搷浣滐紝鎹熷潖闈㈡敹鏁涗负銆屽畬鏁存棫鏂囦欢鎴栧畬鏁存柊鏂囦欢銆嶃€?
  Future<void> save(InferenceSettings settings) async {
    final path = await _resolvePath();
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()));
    await tmp.rename(path);
  }
}
