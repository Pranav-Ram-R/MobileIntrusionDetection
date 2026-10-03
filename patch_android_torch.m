function patch_android_torch(mdl, install)
%PATCH_ANDROID_TORCH  Add camera-LED control to the generated Android app.
%
%   The Android support package has no flashlight block, so the model sends
%   the LED state through a ToApp block (method "TorchControl", int32 input).
%   This script inserts that Java method into the generated main activity,
%   then builds and installs the APK with Gradle.
%
%   Workflow
%     1. build_android_model
%     2. In the model: Hardware tab > Build drop-down > Build   (NOT Deploy)
%     3. patch_android_torch('ids_android_app')        % patch + install + launch
%        patch_android_torch('ids_android_app', false) % patch only, then open
%           <model>_ert_rtw/<model> in Android Studio and press Run
%   Re-run step 3 after every rebuild, because Simulink regenerates the Java.
%
%   What it does, in plain words: Simulink turns the model into an Android
%   Studio project. We open the generated Java file as text, paste one
%   method (TorchControl) before the last closing brace, then call Gradle
%   (Android's build tool, like make or CMake) to compile and install it.
%   This is the only place where Java is involved, and it is a text patch.

% ---- defaults for optional arguments ----
if nargin < 1, mdl = 'ids_android_app'; end
if nargin < 2, install = true; end

% ---- find the generated project folder <model>_ert_rtw ----
% Simulink writes it into the current folder, so look there first and then
% next to this script.
root = fullfile(pwd, [mdl '_ert_rtw']);
if ~isfolder(root)
    here = fileparts(mfilename('fullpath'));
    root = fullfile(here, [mdl '_ert_rtw']);
end
if ~isfolder(root)
    error('Generated project %s_ert_rtw not found. Run Hardware > Build first.', mdl);
end

% ---- locate the main activity (the class the native code calls into)
% First guess: a file named after the model. "**" searches all subfolders.
jf = dir(fullfile(root, '**', [mdl '.java']));
if isempty(jf)
    % Fallback: the Java file that loads the native library and extends a class.
    jall = dir(fullfile(root, '**', '*.java'));
    for k = 1:numel(jall)
        s = fileread(fullfile(jall(k).folder, jall(k).name));     % read whole file as one string
        if contains(s, 'System.loadLibrary') && contains(s, 'extends')
            jf = jall(k);
            break;
        end
    end
end
if isempty(jf)
    error('Main activity Java file not found under %s', root);
end
jpath = fullfile(jf(1).folder, jf(1).name);       % full path of the Java file
code  = fileread(jpath);                          % the file content as a string

% ---- insert the TorchControl method (once) ----
% The marker text IDS_TORCH_PATCH tells us it was already patched.
if contains(code, 'IDS_TORCH_PATCH')
    fprintf('Already patched: %s\n', jpath);
else
    m = torch_java();                             % the Java method as text
    % If Simulink already generated an empty TorchControl stub (from the
    % ToApp block) find its opening line with a regular expression.
    [s0, e0] = regexp(code, 'public\s+void\s+TorchControl\s*\([^)]*\)\s*\{', 'once');
    if ~isempty(s0)
        % replace an existing stub body
        % Walk forward counting braces until the stub body closes.
        depth = 1; k = e0 + 1;
        while depth > 0 && k <= numel(code)
            if code(k) == '{', depth = depth + 1; end
            if code(k) == '}', depth = depth - 1; end
            k = k + 1;
        end
        code = [code(1:s0-1) m code(k:end)];      % text before the stub + our method + text after it
    else
        last = find(code == '}', 1, 'last');     % closing brace of the activity class
        code = [code(1:last-1) newline m newline code(last:end)];   % put the method just before it
    end
    fid = fopen(jpath, 'w');                      % open for writing, like open(path, "w")
    fwrite(fid, code);
    fclose(fid);
    fprintf('Patched %s\n', jpath);
end

% ---- patch-only mode: stop here and let the user press Run in Android Studio ----
if ~install
    fprintf('Open %s in Android Studio and press Run.\n', fileparts(fileparts(jpath)));
    return;
end

% ---- build + install with Gradle
% gradlew.bat is the Gradle wrapper script that the generated project ships.
gw = dir(fullfile(root, '**', 'gradlew.bat'));
if isempty(gw)
    warning('gradlew.bat not found. Open the project folder in Android Studio and press Run.');
    return;
end
proj = gw(1).folder;                              % project folder that contains gradlew.bat
% Gradle needs a Java runtime. If JAVA_HOME is unset try the one bundled with Android Studio.
if isempty(getenv('JAVA_HOME'))
    for jb = {'C:\Program Files\Android\Android Studio\jbr', 'C:\Program Files\Android\Android Studio\jre'}
        if isfolder(jb{1}), setenv('JAVA_HOME', jb{1}); break; end
    end
end
fprintf('Building and installing (gradlew installDebug) in %s ...\n', proj);
% system() runs a shell command (subprocess.run). st = exit code, out = text output.
[st, out] = system(sprintf('cd /d "%s" && gradlew.bat installDebug', proj));
disp(out);
if st ~= 0
    error('Gradle build failed. Open %s in Android Studio to see the error.', proj);
end

% ---- launch the app
% Find the Android application id (package name) in build.gradle, then
% start the app with adb (Android Debug Bridge, the USB command line tool).
appId = '';
gf = dir(fullfile(proj, '**', 'build.gradle'));
for k = 1:numel(gf)
    tok = regexp(fileread(fullfile(gf(k).folder, gf(k).name)), 'applicationId\s*[= ]\s*["'']([^"'']+)', 'tokens', 'once');
    if ~isempty(tok), appId = tok{1}; break; end
end
adb = fullfile(getenv('LOCALAPPDATA'), 'Android', 'Sdk', 'platform-tools', 'adb.exe');   % default SDK location
if ~isfile(adb), adb = 'adb'; end                 % otherwise rely on adb being on the PATH
if ~isempty(appId)
    % "monkey" with the LAUNCHER category simply starts the app's main screen.
    system(sprintf('"%s" shell monkey -p %s -c android.intent.category.LAUNCHER 1', adb, appId));
    fprintf('Launched %s\n', appId);
end
end

% ------------------------------------------------------------------------
function m = torch_java()
%TORCH_JAVA  The Java method to insert, returned as text.
%   Each quoted line is one line of Java. strjoin puts newlines between them.
%   TorchControl(int[] data) receives the LED value from the ToApp block
%   (nonzero = on). It finds the first camera that has a flash and switches
%   its torch with the Camera2 API. It needs Android 6 (API 23) or newer.
%   Calls that would change nothing are skipped, and errors only get logged,
%   so a camera problem can never crash the app.
m = strjoin({
'    // IDS_TORCH_PATCH: camera LED control for the ToApp block "TorchControl"'
'    private boolean idsTorchOn = false;'
'    private String idsTorchCam = null;'
'    public void TorchControl(int[] data) {'
'        final boolean on = (data != null && data.length > 0 && data[0] != 0);'
'        if (on == idsTorchOn) return;'
'        idsTorchOn = on;'
'        if (android.os.Build.VERSION.SDK_INT < 23) return;'
'        try {'
'            android.hardware.camera2.CameraManager cm = (android.hardware.camera2.CameraManager)'
'                    getSystemService(android.content.Context.CAMERA_SERVICE);'
'            if (idsTorchCam == null) {'
'                for (String id : cm.getCameraIdList()) {'
'                    Boolean f = cm.getCameraCharacteristics(id).get('
'                            android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE);'
'                    if (f != null && f) { idsTorchCam = id; break; }'
'                }'
'            }'
'            if (idsTorchCam != null) cm.setTorchMode(idsTorchCam, on);'
'        } catch (Exception e) {'
'            android.util.Log.e("IDS", "TorchControl failed", e);'
'        }'
'    }'
}, newline);
end
