; Hooks for the NSIS installer.
;
; Install: until 0.3.9 the app was called Coucou, so it was installed as its own program
; ("Coucou" in Apps, %LOCALAPPDATA%\Coucou). Installing Lumo removes that old program first,
; silently, so there aren't two copies starting together. Settings live in %APPDATA%\Coucou
; and are not touched; the relay, inbox and log are put back by Lumo at launch.
;
; Uninstall: the app stages coucou-hook.exe into %LOCALAPPDATA%\Coucou\bin at launch, so the
; installer never recorded it and the default uninstaller leaves it behind. The inbox and the
; log live in the same place and are ours too.
;
; Claude Code's own settings.json is deliberately NOT touched here: it belongs to
; the user, it may contain hooks from other tools, and rewriting somebody's
; config from an uninstaller with no diff and no consent is exactly what the rest
; of this app goes out of its way not to do. A relay that is gone exits 0 without
; printing anything, so a leftover entry costs nothing beyond a dead path.

!macro NSIS_HOOK_PREINSTALL
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Coucou" "UninstallString"
  ${If} $0 != ""
    nsExec::Exec 'taskkill /IM Coucou.exe /F'
    Pop $1
    ${If} ${FileExists} "$LOCALAPPDATA\Coucou\uninstall.exe"
      ExecWait '"$LOCALAPPDATA\Coucou\uninstall.exe" /S _?=$LOCALAPPDATA\Coucou'
      Delete "$LOCALAPPDATA\Coucou\uninstall.exe"
    ${Else}
      ExecWait '$0 /S'
    ${EndIf}
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Coucou"
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  RMDir /r "$LOCALAPPDATA\Coucou\bin"
  RMDir /r "$LOCALAPPDATA\Coucou\inbox"
  Delete "$LOCALAPPDATA\Coucou\coucou.log"
!macroend
