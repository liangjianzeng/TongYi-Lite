# TongYi-Lite 椤圭洰鎸囦护 / 璁板繂

## 鐪熸満鎵撳寘瀹夎锛堥噸瑕佽鍒欙紝鍔″繀閬靛畧锛?

> **鏇存柊瀹夎鐪熸満鏃讹紝缁濅笉瑕?鍏堝嵏杞藉啀瑁?**锛坄adb uninstall` + `adb install`锛夈€?
> 鍗歌浇浼氭竻鎺夊簲鐢ㄦ暟鎹紝鍖呮嫭宸蹭笅杞界殑绔晶妯″瀷缂撳瓨锛堜緥濡?qwen3.5-4b锛岄噸鏂颁笅杞藉緢璐瑰姴锛夈€?

**姝ｇ‘鍋氭硶**锛氬缁堣蛋**瑕嗙洊鏇存柊**锛屼繚鐣欐ā鍨嬬紦瀛橈細

```bash
adb install -r app-debug.apk    # -r = replace/update锛屼笉娓呮暟鎹?
```

- 鍙湪闇€瑕佸交搴曟竻鏁版嵁锛堟崲妯″瀷/鍑洪棶棰樻椂锛夋墠鑰冭檻鍗歌浇锛屼笖瑕佸厛鍛婄煡鐢ㄦ埛妯″瀷浼氳娓呴櫎銆?
- 瀹夎琚?`INSTALL_FAILED_USER_RESTRICTED` 鎷掔粷鏃讹紝鍔?`-t` 骞惰鐢ㄦ埛鍦ㄨ澶囦笂鐐瑰厑璁革細`adb install -r -t app-debug.apk`銆?

## 鏋勫缓鐜澶囧繕

- **榛樿鎵撳寘绛栫暐锛?026-08-08 璧凤級**锛氭瘡娆℃瀯寤洪粯璁?**debug + release 涓€璧锋墦**锛?
  闄ら潪鐢ㄦ埛鍙偣鍚嶄竴涓€俤ebug 鐢ㄤ簬鐪熸満瀹夎璋冭瘯锛宺elease 鐢ㄤ簬鐢熶骇鍒嗗彂銆?
  涓よ€呭叡鐢?`CN=TongYiLite` 绛惧悕銆?
- 鏈」鐩槸 Flutter + NDK(CMake + llama.cpp)銆?
- `flutter build apk --debug` 鍦ㄦ湰鏈?gradle 鍚姩 `flutter.bat` 浼氶潤榛樺け璐ワ紙Windows/gradle 鎵瑰鐞嗛棶棰橈級銆?
  **workaround**锛氬厛 `flutter assemble ... debug_android_application` 鐢熸垚 kernel/assets锛?
  鍐嶇敤 `./gradlew.bat assembleDebug -x compileFlutterBuildDebug` 鎵撳寘锛圢DK 鍏ㄩ噺缂栬瘧 + 閾炬帴锛夈€?
- NDK 鏋勫缓鐩綍 `.cxx` 鑻ヨ娈嬬暀杩涚▼锛坄glslc.exe`/`vulkan-shaders-gen.exe`锛夐攣瀹氫細鎶?
  "Device or resource busy" / access-denied锛岄渶鍏堢粓姝㈠搴旇繘绋嬪啀鍒?`.cxx`銆?
- gradle 瀹堟姢杩涚▼鍙兘鎸佹湁 `.cxx` 閿佸鑷?`buildCMakeDebug` 鍋跺彂澶辫触锛歚./gradlew.bat --stop` 鍚庨噸璇曘€?
- 鏋勫缓/瀹夎鍓嶅厛 `adb devices` 纭璁惧鍦ㄧ嚎锛涜澶囧彲鑳藉洜 USB 鏂紑鑰屾秷澶憋紝闇€绛夊緟鎴栭噸杩炪€?

## APK 鏋勫缓浜х墿鍦板潃锛堟墦鍖呭繀璁帮級

> **姣忔鏋勫缓鍚庯紝鎶?APK 杈撳嚭鐩綍鍦板潃鍐欒繘杩欐潯澶囧繕**锛屾柟渚跨敤鎴风洿鎺ユ壘鍖呫€?

- **APK 杈撳嚭鐩綍**锛歚build\app\outputs\flutter-apk\`锛圵indows 缁濆璺緞
  `E:\DTXY\TongYi-Lite\build\app\outputs\flutter-apk\`锛夈€?
- debug 鍖咃細`app-debug.apk`锛堢湡鏈鸿皟璇曪紝`adb install -r` 瑕嗙洊瀹夎锛夈€?
- release 鍖咃細`app-release.apk`锛堢敓浜у垎鍙戯級銆?
- 鏋勫缓鍚?*蹇呴』**鍒楀嚭璇ョ洰褰曠殑 APK 鍚?澶у皬/鏃堕棿锛屽苟鎶婄洰褰曞湴鍧€鍙戠粰鐢ㄦ埛銆?

## APK 绛惧悕锛堥噸瑕佽蹇嗭級

> **姝ｇ‘绛惧悕鏄?`CN=TongYiLite`锛圤=DGXSpark锛夛紝涓嶆槸涓存椂鐢熸垚鐨?dev keystore銆?*

- **绛惧悕璇佷功**锛歚CN=TongYiLite, OU=Dev, O=DGXSpark, L=Wuhan, ST=Hubei, C=CN`
  SHA-256 鎸囩汗锛歚FB:BE:1B:6C:F8:79:AB:94:1A:65:CD:D7:A7:A8:DD:6F:5A:6B:B6:40:41:2D:E3:8C:43:CB:89:4F:08:88:69:92`
- **绛惧悕鏂囦欢**锛歚android/key.jks` + `android/key.properties`锛堝潎琚?`.gitignore` 鎺掗櫎锛屼笉鎻愪氦杩滅▼锛夈€?
  `key.properties`锛歚storePassword=android` / `keyAlias=androiddebugkey` / `storeFile=../key.jks`
- **閾佸緥**锛氳鐩栨洿鏂板畨瑁呭繀椤讳繚鎸佸悓涓€绛惧悕锛堝惁鍒?`INSTALL_FAILED_UPDATE_INCOMPATIBLE`锛夈€傛瀯寤烘椂鑻ュ彂鐜?APK 绛惧悕涓嶆槸 `CN=TongYiLite`锛堟瘮濡傚彉鎴愪簡涓存椂鐢熸垚鐨?`CN=TongYi-Lite Dev`锛夛紝璇存槑绛惧悕鏂囦欢涓嶅锛岄渶鏍稿 `key.jks`銆?
- 鏂扮幆澧?clone 鍚庤嫢绛惧悕鏂囦欢缂哄け锛氫粠婧愬伐浣滃尯鎷疯礉锛屾垨鐢?`keytool -genkey -dname "CN=TongYiLite, OU=Dev, O=DGXSpark, L=Wuhan, ST=Hubei, C=CN"` 閲嶆柊鐢熸垚骞跺啓 `key.properties`銆?

## 鍏抽敭鏁欒锛欳MAKE_C_FLAGS_DEBUG 浼氳 NDK 宸ュ叿閾鹃潤榛橀《鎺夛紙CPU 鍐呮牳澶卞幓 -O3 鈫?鍏ㄦā鍨嬪彉鎱級

> **琛€娉暀璁紙2026-08-07 鐪熸満瀹氫綅锛?*锛歚set(CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG")` 鐪嬩技姝ｇ‘锛屼絾
> **Android NDK 宸ュ叿閾句細鍦?Debug 閰嶇疆閲嶆柊濂椾笂鑷繁鐨?`-g`锛岄潤榛樿鐩栬鍙橀噺**锛屽鑷?`-O3 -DNDEBUG` 鏍规湰娌＄敓鏁堛€?
> 琛ㄧ幇锛?*鎵€鏈夋ā鍨嬪悓绛夐檷閫?*锛?.8B 1.2 tok/s銆?.7B ~1.2锛夛紝鏁堟灉鍍?鏈€鏃╂病鍋?KleidiAI"鈥斺€斿洜涓洪噺鍖?matmul
> 鍐呮牳浠ラ粯璁?`-O0` 缂栬瘧銆傛鏃?KleidiAI 鍐呮牳铏界紪杩涘幓浜嗭紙`-march` 鏈夛級锛屼絾娌′紭鍖栫骇鍒瓑浜庢病鍔犻€熴€?

**楠岃瘉閾佽瘉**锛氱湅 `.cxx/.../compile_commands.json`锛岃嫢 ggml-cpu/kleidiai 婧愭枃浠跺彧鏈?`-march` 鑰?*鏃?`-O3`銆佹棤 `-DNDEBUG`**锛屽嵆涓嫑銆?

**姝ｇ‘鍋氭硶**锛氭敼鐢?NDK 瑕嗙洊涓嶄簡鐨勭洰褰曠骇閫夐」锛堜細浼犵粰 llama/ggml-cpu/kleidiai/mtmd 鎵€鏈夊瓙鐩綍鐩爣锛夛細
```cmake
add_compile_options(-O3)
add_compile_definitions(NDEBUG)
```
鏀?CMake 鍚庡繀椤?*娓?`.cxx` 鍏ㄩ噺閲嶅缓**锛屽苟鏍稿 compile_commands 鍚屾椂鍚?`-O3 -DNDEBUG -march` 鎵嶇畻鐢熸晥銆?

## 鍏抽敭鏁欒锛欳ortex-A78 涓嶆敮鎸?i8mm 鈫?SIGILL 鎾?crashes all backends

> **鏍瑰洜锛?026-08-08 鐪熸満瀹氫綅锛?*锛歚GGML_CPU_ARM_ARCH` 璁句负 `armv8.4-a+dotprod+i8mm`锛?
> 浣嗗ぉ鐜?8200 / 澶╃帒 920 鐨?CPU 澶ф牳鏄?Cortex-A78锛圓RMv8.2-A锛夛紝鍙敮鎸?dotprod锛?
> **涓嶆敮鎸?i8mm**锛堥渶 ARMv8.6-A/ARMv9锛夈€俫gml-cpu 鐨?i8mm kernel 鍦ㄨ繖浜涙牳蹇冧笂鎵ц
> `i8mm` 鎸囦护 鈫?**SIGILL**锛屽穿婧冨彂鐢熷湪鍏变韩鐨?CPU 鍔犺浇/repack 璺緞锛屼笌鎺ㄧ悊鍚庣鏃犲叧锛?
> 鍥犳"涓変釜鍚庣鍏ㄥ穿"銆?

- **鍨嬪彿纭**锛氬ぉ鐜?8200 = 1脳A78@3.1GHz + 3脳A78 + 4脳A55锛涘ぉ鐜?920 = 2脳A78 + 6脳A55銆?
  鍧囦负 ARMv8.2-A锛宍+dotprod`锛屾棤 `i8mm`銆?
- **淇**锛歚android/app/src/main/cpp/CMakeLists.txt` 涓?
  `set(GGML_CPU_ARM_ARCH armv8.4-a+dotprod+i8mm ...)` 鈫?`armv8.2-a+dotprod`銆?
  KleidiAI 鐨?dotprod 鍐呮牳浠嶅彲鐢紝i8mm 閲忓寲鍐呮牳涓嶅彲鐢紙鎬ц兘褰卞搷鍙帴鍙楋級銆?
- **楠岃瘉鍔ㄤ綔**锛氭竻 `.cxx` 鍏ㄩ噺閲嶇紪 + 涓ゅ彴澶╃帒涓夊悗绔紙CPU / OpenCL / Vulkan锛夊悇璺戜竴閬?
  鍔犺浇+鎺ㄧ悊 + 楂橀€?8s Gen 4 鍥炲綊銆?
- **鍚庣画瑙傚療**锛欸PU 鍚庣锛圡ali锛夌殑 ADRENA_KERNELS 闂涓庢淇鏃犲叧锛屾槸鐙珛绾胯矾銆?
  `n_ubatch=16` 闄愬埗鍦?dotprod 涓嬪彲璇曟帰鎻愬洖 512锛屼絾鍏堥獙璇佷笉宕┿€?

## 鍏抽敭鏁欒锛歠lutter assemble 杈撳嚭璺緞 鈮?gradle 璇诲彇璺緞锛圖art 鏀瑰姩"瑁呬笉杩?APK锛?

> **琛€娉暀璁?*锛氭敼浜?Dart 浠ｇ爜鍚庯紝鍏?`flutter assemble` + `gradlew assembleDebug -x compileFlutterBuildDebug`锛?
> 瑁呭嚭鏉ョ殑 APK **鍙兘浠嶆槸鏃т唬鐮?*鈥斺€斿洜涓轰袱涓伐鍏疯鍐欑殑 kernel 璺緞涓嶄竴鑷达細
>
> - `flutter assemble -o build/flutter-assemble ...` 鎶婃渶鏂?kernel 鍐欏埌
>   `build/flutter-assemble/flutter_assets/kernel_blob.bin`锛?
> - 浣?gradle 鎵撳寘鏃剁敤鐨勬槸 **`build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin`**锛堟棫鎷疯礉锛夛紝
>   `-x compileFlutterBuildDebug` 璺宠繃浜?flutter 缂栬瘧锛?*涓嶄細鑷姩鍒锋柊杩欎釜璺緞**銆?
>
> 缁撴灉锛歎I 鏀逛簡鍗婂ぉ锛岃涓婂幓鐣岄潰姣棤鍙樺寲锛岃繕浠ヤ负浠ｇ爜娌″啓瀵光€斺€斿疄闄呮槸鎵撳寘浜嗘棫 Dart銆?
>
> **姝ｇ‘鍋氭硶锛堟瘡娆?Dart 鏀瑰姩鍚庡繀椤诲仛锛?*锛?
> ```bash
> flutter assemble -o build/flutter-assemble --define=BuildMode=debug --define=TargetPlatform=android-arm64 debug_android_application
> cp -r build/flutter-assemble/flutter_assets/* build/app/intermediates/flutter/debug/flutter_assets/
> cd android && gradlew.bat assembleDebug -x compileFlutterBuildDebug
> ```
> 鍗筹細**鍏堟妸鏈€鏂?flutter_assets 鍚屾瑕嗙洊鍒?gradle 鐨?intermediates/flutter/debug锛屽啀鎵撳寘**銆?
> 鍙敤 `ls -la build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin` 纭澶у皬/鏃堕棿宸叉洿鏂般€?

## 鍏抽敭鏁欒锛歁TP 鏄叏灞€寮€鍏充細"鐐逛竴涓叏寮€鍏ㄥ叧"

> MTP 寮€鍏虫渶鍒濆仛鎴愬叏灞€涓€涓?`bool enableMtp`锛岀敤鎴风偣鏌愪釜妯″瀷寮€鍏筹紝**鎵€鏈夋ā鍨嬩竴璧峰彉**銆?
> 搴旀敼鎴?*鎸夋ā鍨?id 鐨?`Map<String, bool>`**锛坄mtpEnabledByModel`锛夛紝姣忎釜妯″瀷鐙珛鎸佷箙鍖栵紝
> 鍔犺浇鏃剁敤 `gpu.mtpEnabled(modelId)` 鍙栧綋鍓嶆ā鍨嬭嚜宸辩殑寮€鍏炽€傝縼绉绘棫閰嶇疆鏃跺叏灞€ bool 涓嶈縼绉讳负寮€锛堜繚鎸侀粯璁ゅ叧锛夈€?

## 鍏抽敭鏁欒锛歳elease 鍖?AOT 鏆傚瓨蹇呴』鐢?app.so 鍘熷悕锛屼笖蹇呴』瀛楃涓茬骇楠屾敹锛?026-09-18 韪╁潙锛?

> `-x compileFlutterBuildRelease` 璺宠繃鍚庯紝libapp.so 鐨勫敮涓€鏉ユ簮鏄?gradle `packJniLibs*` 浠诲姟锛?
> 瀹冧粠 **`build/app/intermediates/flutter/release/arm64-v8a/app.so`锛堝師鍚?app.so锛侊級** 鍙栨枃浠讹紝
> 鎵撳寘鏃舵墠鏀瑰悕鎴?`lib/arm64-v8a/libapp.so`銆傛斁鎴?`libapp.so` 浼氭墦鎴?`liblibapp.so`锛團lutter 璧蜂笉鏉ワ級锛?
> 鍒犳帀 merged_native_libs 鍐嶆寚鏈涘畠閲嶆柊鐢熸垚鏄敊瑙夆€斺€攆lutter 浠诲姟琚?`-x` 璺宠繃锛屾病浜哄杺浜х墿銆?

**release 鎵撳寘姝ｇ‘娴佺▼**锛歚flutter assemble release_android_application` 鈫?鎶婅緭鍑虹殑
**`app.so` 鍘熷悕**鎷峰埌 `intermediates/flutter/release/arm64-v8a/`锛宖lutter_assets 鎷峰埌鍚岀骇 `flutter_assets/` 鈫?gradlew銆?

**鎵撳寘鍚庡繀鍋氬瓧绗︿覆绾ч獙鏀讹紙鏈杩為敊涓ゆ鎵嶆姄鍒扮殑鍘熷洜锛氬彧鐪嬫椂闂存埑/澶у皬锛?*锛?
```bash
python -c "import zipfile; d=zipfile.ZipFile(apk).read('lib/arm64-v8a/libapp.so'); print(d.count('鏂颁唬鐮佸瓧鏍?.encode('utf-16-le')), d.count('鏃у瓧鏍?.encode('utf-16-le')))"
```
AOT 涓插湪 libapp.so 閲屾槸 **UTF-16LE**锛宒ebug kernel_blob 鏄?UTF-8锛涚‘璁?NEW>0 涓?OLD=0銆?
`app-debug.apk`/`app-release.apk` 閲?鏃?Dart 骞界伒"灏辩敤杩欐嫑褰撳満楠屽案銆?

## 鐪熸満璋冭瘯娉ㄦ剰

- 灞忓箷浼戠湢锛坄mWakefulness=Dozing`锛夋椂 `uiautomator dump` 杩斿洖**绌鸿妭鐐?*锛屾槗璇垽"UI 娌℃覆鏌?銆?
  鍏?`input keyevent KEYCODE_WAKEUP` + `KEYCODE_MENU` 鍞ら啋锛屽啀 dump 楠岃瘉鐣岄潰銆?
- Flutter 鐨?`Switch` 鍦?uiautomator 閲屽彲鑳戒笉鏄剧ず涓?`android.widget.Switch` 绫伙紙鍙兘鏄剧ず涓哄甫
  `checked` 灞炴€х殑鏅€?View锛夛紝鍒彧鐪?class 鍚嶅垽鏂紑鍏虫槸鍚﹀瓨鍦ㄣ€?

## 閲嶈锛氬綋鍓嶆ā鍨嬩笉鏀寔瑙嗚鐞嗚В锛堣皟璇曠鐢?鐪嬪浘鐗?鎴浘"锛?

> **鐢ㄦ埛涓嶄富鍔ㄥ杺鍥撅紱褰撳墠椹卞姩妯″瀷涓嶆敮鎸佽瑙夛紝鏃犳硶鐪熸"鐪?鍥剧墖/鎴浘銆?*
> 涓€鏃︿换鍔℃祦绋嬮噷鍑虹幇"鏌ョ湅鎴浘/鍥剧墖"杩欑被渚濊禆瑙嗚鐨勬楠わ紝妯″瀷浼氭嬁涓嶅埌浠讳綍鍥惧儚鍐呭锛?
> 浠诲姟浼?*褰诲簳鍍垫**锛堝崱鍦ㄧ瓑鍥俱€佽鍒ょ晫闈㈢瓑姝诲惊鐜級銆?

**閾佸緥**锛?
- 璋冭瘯/楠岃瘉涓€寰嬭蛋**鏂囨湰閫氶亾**锛歚uiautomator dump` 鐨?XML 鏂囨湰銆乣adb logcat`銆乣dumpsys`銆?
  鏂囦欢鍐呭锛坄cat`/`Read`锛夌瓑鈥斺€?*缁濅笉渚濊禆鎴浘鍒よ**銆?
- 涓嶄富鍔ㄧ敓鎴愩€佷笉涓诲姩鏌ョ湅 `screen.png` 涔嬬被鐨勬埅鍥句骇鐗╋紱鍗充究瀛樺湪涔熶笉鎶婂浘鍍忓唴瀹瑰綋鐪熴€?
- 鍒ゆ柇 UI 鐘舵€佸彧鐪嬫枃鏈妭鐐?灞炴€э紙`text`銆乣content-desc`銆乣checked`銆乣bounds`锛夛紝
  涓嶈鍐?鎵撳紑鎴浘纭涓€涓?杩欑姝ラ銆?

## 閲嶈锛氶€氳繃 DSH Phone 鎶?APK 涓嬪彂鍒版墜鏈虹殑瑙﹀彂鏈哄埗锛?026-09-05 瀹炴祴鍙锛?

> **鑳屾櫙**锛氱敤鎴峰湪鎵嬫満涓婄敤 `E:\DTXY\DSH-Phone` 杩欎釜 App 閫氳繃 SSH 闅ч亾杩炲洖鏈満锛?
> 鎯冲湪鎵嬫満涓婄洿鎺ヤ笅杞藉垰鎵撳寘鐨?APK銆侱SH Phone 鐨?璧勬簮涓嬭浇"鑳藉姏閾捐矾锛?
>
> - 鎵嬫満 webview 娉ㄥ叆 `artifactBridgeJs`锛岀洃鍚?DSH Web UI 閲?*鎴愭灉锛坅rtifact锛夌偣鍑?*锛?
> - 鍙湁褰?Web UI 閲屽嚭鐜?*浜х墿鎸夐挳锛坒ile-mention chip锛宍title` 瀛樿繙绔矾寰勩€?
>   甯?`.apk` 鍚庣紑 鈫?褰掔被涓?resource 璧颁笅杞斤級**鏃讹紝鎵嬫満鎵嶄細瑙﹀彂 SFTP 闅ч亾涓嬭浇锛?
> - 璇ヤ骇鐗╂寜閽敱 **`write` 宸ュ叿璋冪敤锛堝甫 `file_path`锛?* 瑙﹀彂锛?*涓嶆槸** gradle 缂栬瘧浜х墿銆?

**涓轰粈涔堜箣鍓嶈Е鍙戜笉浜?*锛欰PK 鏄?`gradle` 缂栬瘧鍑烘潵鐨勶紝涓嶆槸閫氳繃 `write` 宸ュ叿璋冪敤浜х敓鐨勶紝
鎵€浠?Web UI 閲?*娌℃湁瀹冪殑浜х墿鎸夐挳** 鈫?鎵嬫満鐐逛笉鍒般€佷笅涓嶄簡銆?
**鍙湁 `write` 宸ュ叿浜у嚭鐨勬枃浠讹紝鎵嶄細琚?Web UI 娓叉煋鎴愬彲鐐瑰嚮鐨勪骇鐗?璧勬簮鎸夐挳銆?*

**姝ｇ‘鍋氭硶锛堣鎵嬫満鑳戒笅杞斤級锛?*
1. 鍏堢‘璁ゆ墜鏈?SSH 杩炵殑鏄摢鍙颁富鏈猴紙`E:\DTXY\DSH-Phone\lib\tunnel_service.dart` 閲岄厤鐨?host锛夛紱
2. 鐢?**`write` 宸ュ叿璋冪敤**鎶?APK 鍐欏埌**鎵嬫満鎵€杩炰富鏈轰笂鐨勬煇涓矾寰?*锛堜笉鏄洿鎺ョ粰璺緞锛夛紱
3. 杩欐牱 Web UI 浼氭妸瀹冩覆鏌撴垚浜х墿鎸夐挳锛屾墜鏈轰竴鐐瑰氨璧?SFTP 闅ч亾涓嬭浇锛坄download_manager.dart`锛夈€?

**璁╄緭鍑烘洿楂樻鐜囪Е鍙戜笅杞界殑浼樺寲寤鸿锛堥拡瀵?DSH Phone锛夛細**
- 鍑℃槸鍙兘涓嬪彂鐨勪簩杩涘埗锛坅pk/zip/鍥剧墖绛夛級锛?*涓€寰嬭蛋 `write` 宸ュ叿鍐欏埌涓€涓槑纭矾寰?*锛?
  涓嶈鍙粰璺緞鏂囨湰鎴?`file://` 閾炬帴鈥斺€斿彧鏈?`write` 鎵嶄細琚瘑鍒负浜х墿銆?
- `write` 鐨?`file_path` 鐢?*甯﹀悗缂€鐨勫畬鏁磋矾寰?*锛坄.apk` 绛夛級锛岀‘淇濆懡涓?
  `artifact_recognizer.dart` 鐨?`resourceSuffixes`锛坄.apk/.zip/.png/.pdf` 绛夛級銆?
- 鑻ユ媴蹇冭矾寰勮 chips 闅愯棌锛宍write` 鍚庡湪鍥炲閲?*鏄惧紡鍐欏嚭璇ュ畬鏁磋矾寰?*锛?
  閰嶅悎 `webview_bridges.dart` 鐨?`findMentionPath` / `collectProducedDirs` 鍏滃簳瑙ｆ瀽銆?
- 澶ф枃浠舵敞鎰?`maxDownloadBytes = 256MB`銆乣maxRemoteReadBytes = 8MB` 涓婇檺锛?
  APK 涓€鑸病闂锛涜秴涓婇檺闇€鎹㈢敤 `download_manager` 鐨勬柇鐐圭画浼犳祦绋嬨€?
- 鎵嬫満渚ч渶寮€鍚?璧勬簮涓嬭浇"寮€鍏筹紙`config.dart` 鐨?`resourceDownloadEnabled`锛岄粯璁ゅ紑锛夛紝
  涓?SSH 闅ч亾宸茶繛涓婂搴斾富鏈恒€?

## llama.cpp 鍗囩骇闂ㄦ锛堝洓閬撻棬锛岀己涓€涓嶇畻鍗囩骇瀹屾垚锛夛紙2026-09-18 瀹炴祴绔嬭锛?

> **鑳屾櫙**锛氬彟涓€鍙板紑鍙戞満鍗囩骇鍒?b11028 鍚?CPU/GPU 鍏ㄥ悗绔參涓€鍊嶁€斺€斿崌绾х被鍥炲綊鍑犱箮閮芥槸**闈欓粯鐨?*
> 锛堜笉宕┿€佷笉鎶ラ敊銆佸姛鑳藉叏瀵癸紝灏辨槸鎱級锛岄槻涓嶄綇瀹冪殑浜哄彧鑳戒簨鍚庤€冨彜銆傛墍鏈夋鏌ュ繀椤?*鏈烘鍖?*锛?
> 楠屾敹鍩哄噯鏄?`docs/backend_benchmark_2026-08-04.md`锛? Elite 瀹炴祴锛歏ulkan 8.60 / OpenCL 8.77 / CPU 4.33 tok/s锛夈€?

**鍗囩骇娴佺▼锛堟湰鏈?b10173鈫抌11028 璧伴€氱殑鎵撴硶锛夛細**
1. **鍏堢畻 fork 澧為噺鍐嶅姩鎵?*锛歚git log --oneline -- third_party/llama.cpp` 鎵句笂娓稿悓姝ョ偣锛堟湰浠撳簱鍩虹嚎 = 涓婃父 `fe8156f`锛夛紝
   `git diff --no-index <涓婃父base> third_party/llama.cpp` 寰楃湡瀹炶ˉ涓侀潰銆?*鍒妸鏈湴琛ヤ竵褰撶浼?*鈥斺€?
   鏈鍙戠幇 XHToken/Spark2.5 宸插悎鍏ヤ笂娓?b11028锛坄spark2-5.cpp` 涓?fork 鐗堜粎 1 琛屽樊寮傘€佹ā鏉挎敼鍚?`Spark2.5.jinja`锛夛紝
   fork 閲屽浣欑殑 `XHToken-Spark-X2.5-1.7B.jinja` 鐩存帴鍒犮€?
2. 鏇挎崲鏍戯細`robocopy <鏂版爲> third_party/llama.cpp /MIR`锛坄Remove-Item` 鍒?.cxx/澶х洰褰曚細鎱㈠埌瓒呮椂锛夈€?

**鍥涢亾楠屾敹闂紙鍏ㄨ繃鎵嶇畻瀹岋級锛?*
1. **缂栬瘧闂?*锛歚gradlew --stop` + 娓?`.cxx` 鍏ㄩ噺閲嶇紪鍚庯紝鎵?`.cxx/Debug/*/arm64-v8a/compile_commands.json`锛?
   ggml-cpu / kleidiai / mtmd / llama core / JNI 鐨勫懡浠よ**蹇呴』鍚屾椂鍚?`-O3 -DNDEBUG`**锛?
   ggml-cpu 涓绘簮鐮佸繀椤?`-march=armv8.2-a+dotprod`锛圢DK 椤舵帀 -O3 鐨勮€佸潙灏辨槸杩欎箞鎶撶殑锛夈€?
   鈿狅笍 鍐欐鏌ヨ剼鏈敞鎰?PowerShell `-match` **澶у皬鍐欎笉鏁忔劅**銆乧ompile_commands 璺緞鏄?*鍙嶆枩鏉?*鈥斺€旀湰娆″樊鐐硅鎶?292 鏉′笉鍚堟牸銆?
2. **鍐呮牳闂?*锛歝onfigure 鎽樿 KleidiAI 蹇呴』 ON锛屼笖瀵硅薄鏂囦欢鏉ヨ嚜 `third_party/kleidiai`锛坴endored锛夛紝**涓嶆槸缃戠粶鎷夊彇**銆?
   鈿狅笍 **FetchContent 椤圭洰鍚嶄細鍙?*锛歚KleidiAI_Download`(fe8156f) 鈫?`kleidiai`(b11028)锛?
   瑕嗙洊鍙橀噺鏄?`FETCHCONTENT_SOURCE_DIR_<鍚嶅瓧澶у啓>`锛屽悕瀛楅敊=闈欓粯澶卞幓 vendored 鐩綍锛?
   app CMakeLists 宸插悓鏃惰鏂版棫涓や釜鍙橀噺鍏滃簳銆侹leidiAI pin 鐗堟湰锛坴1.24.0锛夎涓?ggml-cpu/CMakeLists.txt 閲?`KLEIDIAI_COMMIT_TAG` 瀵瑰緱涓娿€?
3. **鍙傛暟闂?*锛歭ogcat 鎶?`[handleLoadModel]`锛屼笌鍗囩骇鍓嶉€愰」 diff锛歚n_gpu_layers=100` /
   `n_ubatch`锛圕PU=16銆丟PU=512锛? `flash_attn=DISABLED` / sampler 閾俱€傜Щ妞?JNI 鏃朵笉璁搁『鎵嬫敼榛樿鍊笺€?
4. **鍩哄噯闂?*锛氬熀绾胯澶囷紙Xiaomi 25053RT47C / 8 Elite锛夊悓 prompt 鍚勫悗绔?3 杞紝tok/s 瀵?8-04 鍩虹嚎锛?
   **鍋忓樊 >卤10% 涓嶈鏀跺伐**锛屾寜 缂栬瘧闂ㄢ啋鍐呮牳闂ㄢ啋涓婃父鍥炲綊 椤哄簭鎺掓煡銆?

**b11028 瀹為檯韪╁埌鐨?API 婕傜Щ锛堜笅娆″崌绾у厛鏌ュ悓绫伙級锛?*
- `mtmd_helper_bitmap_init_from_file()` 鍔犱簡绗?4 鍙?`mtmd_helper_init_opt`锛屽浘鐗囪矾寰勪紶 `mtmd_helper_init_opt_default()`锛圝NI 宸蹭慨锛夈€?
- **`MTMD_BACKEND_DEVICE` 鐜鍙橀噺鍦?b11028 琚垹**锛坒e8156f `clip.cpp:189` 鐨?`getenv` 娌′簡锛夆啋 瑙嗚缂栫爜鍚庣蹇呴』鏀硅
  `mtmd_context_params.device`锛坄ggml_backend_reg_by_name("vulkan"/"opencl")` + `ggml_backend_reg_dev_get(reg,0)`锛夈€?
  **闈欓粯澶辨晥涓嶆姤閿?*锛岃瑙夊浠庢涓嶈窡涓诲悗绔€斺€擩NI 宸蹭慨锛堜繚鐣?setenv 鍏煎鏃у簱锛夈€?
- 鈿狅笍 UI 鎶ラ敊鏂囨浼氭寚閿欐柟鍚戯細model_provider 鏃ч€昏緫鍙 `loadModel` 杩斿洖 false 涓旀ā鍨嬬被鍨嬫槸 vision 灏辨樉绀?
  "mmproj 鎶曞奖鍣ㄥ姞杞藉嚭閿?鈥斺€斾笂涓嬫枃 OOM/涓绘ā鍨嬪け璐ュ叏琚敥閿?mmproj锛堝凡鏀逛负鍙鐪熷疄鏃ュ織锛夈€?
  **鏁欒锛氱湡鍑剁湅寮曟搸鏃ュ織鏈€鍚庝竴姝ワ紝鍒俊绾㈡潯鏍囬銆?* 鏈満 b11028 瀹夸富澶嶇幇锛坢ingw `llama-mtmd-cli` + 鍚屾 4B/mmproj锛?
  鍔犺浇鎺ㄧ悊鍏ㄨ繃锛屼笂娓?mtmd 瀵?unsloth Qwen3.5 mmproj 鏃犵姜銆?
- ggml-opencl 鐩存帴鐢?CL2.1 鏍稿績鍏ュ彛 `clGetKernelSubGroupInfo` 鈫?`third_party/opencl-stub/opencl_stub.c` 宸插姞杞彂
  锛堝崌绾у悗閾炬帴鎶?`undefined symbol: cl*` 灏辩収鐜版湁 CL_FORWARD 妯″紡琛ワ級銆?
- Vulkan 鍚庣 24k 琛屽ぇ閲嶅啓锛堟媶鍒嗗嚭 buffers/types/push-constants 绛夋柊鏂囦欢锛夛紝
  **Mali 宕╂簝缂撹В闇€鍦?b11028 涓婇噸楠?*锛堟棫"鍒?copy_transpose_02.comp"寮忔敼鍔ㄦ湭鍥炲甫锛岃嫢 Mali 鍐嶅穿浠庤繖閲屾煡锛夈€?
- `llama-ext.h` 鐨?`llama_set_embeddings_nextn`锛圡TP/dspark staging API锛変粛鍦紝MTP 浠ｇ爜鏈姩銆?

**闅旂鍙ｈ瘈**锛氬厛鍦ㄦ湰鏈洪噸缂?*鏃х増**鈥斺€旀棫鐗堜篃鎱?鐜闂锛圢DK 鐗堟湰/鏋勫缓绫诲瀷/璁惧涓嶅悓锛夛紝鏃х増蹇?鏂版爲闂銆?
鎱竴鍊嶈繖绉嶉棶棰橈紝鏈夎繖鍥涢亾闂ㄥ氨娲讳笉杩囧綋澶┿€?

## 鏅鸿兘浣?杩唬涓€涓や笅灏卞仠 / 娌℃纭粨鏋?鏍瑰洜涓庝慨澶嶏紙2026-09-27 v0.2.4-agent-stall-fix锛?

> 鐢ㄦ埛鍙嶉锛氭櫤鑳戒綋妯″紡璺戜竴涓よ疆灏辨墽琛屼笉涓嬪幓銆佽緭鍑烘病瀹屾垚浠诲姟銆傚畾浣嶅埌**涓夋潯闈欓粯鍗℃璺緞**锛?
> 鍏卞悓鐗瑰緛鏄?*涓嶅穿涓嶆姤閿欍€佷换鍔″崐閫旇€屽簾褰撴垚鍔?*鈥斺€斿拰鍗囩骇鍥炲綊涓€鏍烽槾闄╋紝楠屾敹闈?鐪嬫湁娌℃湁绾㈠瓧"姘歌繙鎶撲笉鍒般€?

**鏍瑰洜 1锛氬伐鍏疯皟鐢ㄥ潡琚?token 棰勭畻鎴柇 鈫?闈欓粯闄嶇骇鎴愭櫘閫氬洖绛旓紙涓诲洜锛?*
- 鐜拌薄锛氭ā鍨嬭緭鍑?`{"name":"file_write","arguments":{"content":"鈥︹€锛堝啓鍒颁竴鍗婅 `maxTokensPerRound=512` 鎷︽柇锛夛紝
  `prompt_json_protocol` 鎷彿涓嶅钩琛?鈫?**鏁存褰撴櫘閫氭枃鏈繑鍥?* 鈫?涓诲惊鐜垽瀹?鏃犲伐鍏疯皟鐢?鈫?鏈疆瀹屾垚"锛?
  浠诲姟娌″仛杩樻樉绀哄緱鍍忔垚鍔熴€?*杩欐槸"杩唬涓€涓や笅灏卞仠銆佹病缁撴灉"鐨勫ご鍙峰厓鍑躲€?*
- 淇锛坄lib/agent/protocol/prompt_json_protocol.dart` `_parseText` 绗?0 姝ヤ笁鍒嗙被锛夛細
  鍏?`_truncatedToolCall` 鍒ゅ畾鈥斺€斺憼 鏂湪瀛楃涓?鍙傛暟鍐呭鍐呴儴 鈫?鎶?`LlmFailureCode.toolCallTruncated`锛堜笉鍙吉閫犳墽琛岋級锛?
  鈶?浠呯己鏀跺熬鎷彿涓旇兘琛ュ叏 鈫?鑷姩琛ユ嫭鍙风収甯告墽琛岋紙鍙傛暟鏃犳崯锛夛紱鈶?琛ュ畬浠嶉潪娉?= 妯″瀷鑷韩璇硶閿欒 鈫?浼橀泤闄嶇骇涓烘枃鏈紝
  **涓嶈鎶ユ埅鏂?*璇鐢ㄦ埛鍘昏皟璁剧疆銆俙failure.dart` 鐨?`LlmRetry` 鎶?toolCallTruncated 绾冲叆鏈夐檺閲嶈瘯棰勭畻銆?
- **鎺掗殰閾佸緥**锛氭櫤鑳戒綋"娌＄粨鏋?鍏堢炕鎺ㄧ悊鏃ュ織鐪嬫槸涓嶆槸鎴柇锛屽埆鍏堟€€鐤戞ā鍨嬬銆傚彲璋冦€屾櫤鑳戒綋姣忚疆鐢熸垚 token銆嶃€?

**鏍瑰洜 2锛氬け璐ヨ疆鍥炴函鍘嗗彶鏃х瓟妗堝啋鍏呮湰杞洖澶嶏紙"閲嶅闂€?bug"锛?*
- 鐜拌薄锛氱浜岃疆璧?turn 鍐呭け璐?鈫?UI 鍙堟樉绀虹涓€杞殑闂€欙紝鍍?妯″瀷鍙細杩欎竴鍙?銆?
- 淇锛歚ReactLoopAgent._turnAnswer` **鍙彇鏈疆 append 鐨?assistant**锛屽け璐ョ疆绌轰覆缁濅笉绌块€忓巻鍙诧紱
  澶辫触鍘熷洜璧?`_turnError` 鈫?chat_provider 鏄庣‘鎶?`鈿狅笍 鏈疆鎵ц澶辫触锛氣€锛屼笉鍐嶆嬁鏃у洖澶嶉《鍖呫€?

**鏍瑰洜 3锛氭瘡杞噸寤?log 鏃?system 钀藉湪娑堟伅涓 鈫?OpenAI 鍏煎鏈嶅姟绔?400 鎷掓敹**
- 鐜拌薄锛氭柊寮曟搸姣忚疆 importFromMessages 鍏堝鍏ュ巻鍙诧紝鏋勯€?agent 鏃舵墠 append system 鈫?
  system 涓嶅湪闃熼 鈫?API 璺嚎 400銆佹湰鍦?chatml 琚腑娈?system 姹℃煋 鈫?琛ㄧ幇涓?鎵ц涓嶄笅鍘?銆?
- 淇锛歚SessionLog.deriveModelMessages` **system 鎭掔疆闃熼**锛堢函鎶曞奖閲嶆帓锛屼笉鐮村潖浜嬩欢搴忎笉鍙橀噺锛夈€?

**鍥炲綊闃茬嚎锛坱est/agent/ 鍏ㄧ豢 241 椤癸紝鍚湰娆℃柊澧烇級**锛氭埅鏂笁鍒嗙被銆乼oolCallTruncated 鏈夌晫閲嶈瘯鍚庣粓鎬?error銆?
lastTurnAnswer 涓嶅洖婧€乻ystem 鏅?append 浠嶆亽闃熼銆?*涓嬫鍔ㄦ櫤鑳戒綋寰幆/鍗忚鍏堣窇 `flutter test test/agent`銆?*

## 鍏抽敭鏁欒锛氬ぇ妯″瀷 GPU 鍔犺浇 OOM 浼氭墦姝绘暣鏈?system_server锛?026-09-27 Bonsai-2 姝绘満妗堬級

> **鐜拌薄**锛欱onsai-2 27B (PTQ1_0, 5.95GB) + OpenCL 鍦ㄥ皬绫?25053RT47C 涓?涓€鎺ㄧ悊灏辨鏈?锛?
> 杩炴涓夊洖锛氭墜鏈烘暣鏈哄崱姝?鈫?Android Watchdog 閲嶅惎銆備笉鏄唴鏍?panic銆佷笉鏄?OpenCL 鍐呮牳 bug銆?
> 涓嶆槸 App 宕╂簝鈥斺€?*logcat 閲屾案杩滅湅涓嶅埌鍑舵墜**锛坰ystem_server 姝绘椂鏃ュ織闅忕紦鍐蹭竴璧锋柇锛夈€?

**閾佽瘉**锛坉ropbox `system_server_pre_watchdog`锛宒umpsys dropbox 鍙法閲嶅惎璇伙級锛?
- `/proc/pressure/memory` some avg60=19.3 / full=12.3锛堜弗閲嶅唴瀛樺仠婊烇級锛沰swapd0 5.5% CPU锛?
- system_server **11897 娆?major faults**锛涗富绾跨▼/Binder/display/AM/Power 鍏ㄩ儴 blocked 30s锛?
- Subject: `Blocked in monitor Watchdog$BinderThreadMonitor 鈥?for 30s` 鈫?鐪嬮棬鐙?reboot銆?

**鏍瑰洜绠楄处**锛氳鏈?**MemTotal 浠?11.0GB**锛堜笉鏄?12锛侊級锛屾棩甯?MemAvailable 鈮?3.5-5GB銆?
Adreno UMA锛歄penCL/Vulkan 鐨勬潈閲嶅拰 KV 閮芥槸绯荤粺 RAM銆俠onsai2 闇€姹?=
鏉冮噸 5.95GB(GPU) + KV @n_ctx4096 鏁?GB + mmap 鏂囦欢宸ヤ綔闆?鈮?8-11GB 鈫?瓒呯墿鐞嗗唴瀛樹竴鍊?鈫?
鍥炴敹椋庢毚楗挎 system_server銆?*涓€浠?Bonsai 27B锛?.8GB锛夋伆濂藉帇绾胯兘娲伙紝bonsai2 瓒呯嚎鍗虫**銆?
CPU 鍚庣鑳芥椿鐨勫師鍥狅細鏉冮噸鏄?mmap 鏂囦欢椤碉紙鍙洖鏀讹級锛岃€?GPU 鍚庣鏄繀 resident 鐨勬嫹璐濄€?

**淇锛堝凡瀹炴柦锛?*锛?
- `tongyilite_jni.cpp` 鍔?**OOM 瀹堝崼**锛氬缓 ctx 鍓嶈 `/proc/meminfo` MemAvailable锛?
  浼扮畻 GPU 鏉冮噸锛堟寜 GPU 灞傛暟鎶樼畻 + dspark 鑽夌锛? KV锛坣_layer脳kv_dim脳f16锛? 1.5GB 澶撮噺锛?
  涓嶅 鈫?**鑷姩涓嬭皟 n_ctx**锛涜繛 n_ctx=512 閮芥斁涓嶄笅 鈫?**鎷掔粷鍔犺浇**骞跺湪搴旂敤鍐呮帹鐞嗘棩蹇楁姤
  "宸叉嫆缁濆姞杞戒互闃叉暣鏈烘鏈?锛堝畞鎷掔粷涓嶆鏈猴級銆傛棩蹇?tag `[oom-guard]`銆?
- `mul_mv_ptq1_0_f32.cl`锛氬熬琛?*璇?*鎸囬拡 clamp 鍒?`ne01-1`锛堝啓鏈潵鏈?guard銆佽娌℃湁锛?
  灏捐瓒婄晫璇绘渶鍚庝竴涓?cl_mem 涔嬪鐨勯〉鍙Е鍙?GPU SMMU 鏁呴殰锛屽睘椤烘墜鍫甸浄锛屼笉褰卞搷鏁板€硷級銆?
- catalog bonsai2锛歚minRamMB` 8192鈫?6384 + 鍔?闇€鈮?6GB鍐呭瓨"鏍囩锛堟敞鎰?minRamMB 浠呭厓鏁版嵁锛?
  Dart 绔?*浠庢湭寮哄埗鎵ц**锛岀湡姝ｇ殑闂告槸 JNI 瀹堝崼锛夈€?

**鎺掓煡鏂规硶璁猴紙涓嬫鏁存満姝绘満鐓ф妱锛?*锛?
1. `dumpsys dropbox | grep -iE 'PRE_WATCHDOG|PANIC|SYSTEM_BOOT'`鈥斺€攑re_watchdog=绯荤粺鍗℃琚嫍鍜紝
   鏃?PANIC=鍐呮牳娌℃锛涢噸鍚悗渚濈劧鍙煡锛坉ropbox 钀界洏锛夈€?
2. 杞偍閲岀湅 `/proc/pressure/*` + major faults + `Subject:` 涓変欢濂楀畾"楗挎杩樻槸宕╂"銆?
3. `getprop sys.boot.reason`銆乣/proc/meminfo` MemTotal 鍏堢畻璐﹀啀璋堜紭鍖栤€斺€?*11GB 鏈哄櫒璺?
   鈮?GB 鏉冮噸鐨?GPU 鍏ㄨ浇鏂规鏄墿鐞嗕笉鍙兘鐨勶紝涓嶆槸 bug**銆?
4. 鍒啀鎷?llama-cli 寰€ /data/local/tmp 鎺ㄤ簡鍙嶅姝绘満鈥斺€?*姝绘満鏃剁幇鍦烘棩蹇楀彧鍦?logcat 瀹炴椂鎶撳彇
   + dropbox 閲屾湁**锛屼簨鍚?`logcat -d` 鎷垮埌鐨勫彧鏈夋柊 boot銆?
