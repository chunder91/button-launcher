; Button Launcher per-user installer (NSIS). Built on Linux by tools/build-nsis.sh; do not build by hand.
; Mirrors Build-Installer.ps1's IExpress install script: per-user, %LOCALAPPDATA%\Programs\Launcher, HKCU Run value
; "ButtonLauncher" ON by default, Start menu shortcuts, HKCU Uninstall\ButtonLauncher, staged swap, keeps buttons.json
; and user-changed pictures. No network access. The PowerShell one-liners come from installer/*.ps1 via generated.nsh.
Unicode true
ManifestDPIAware true
RequestExecutionLevel user
SetCompressor /SOLID lzma
!include LogicLib.nsh
!include FileFunc.nsh
!include generated.nsh          ; VERSION, SRC, PAYLOAD_FILES macro, PICS_SAVE, PICS_RESTORE, STOP_LAUNCHER

!define APPNAME "Launcher"
!define KEYNAME "ButtonLauncher"
!define UNKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall"
!define RUNKEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define PS `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command`

Name "${APPNAME}"
OutFile "${OUTFILE}"
Icon "${SRC}\images\app.ico"
UninstallIcon "${SRC}\images\app.ico"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
ShowInstDetails show
ShowUninstDetails show
BrandingText "${APPNAME} ${VERSION}"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Charles Cipolla"
VIAddVersionKey "FileDescription" "${APPNAME} Setup"
VIAddVersionKey "LegalCopyright" "Charles Cipolla"
Page instfiles
UninstPage instfiles

Var Stage
Var Old
Var Keep
Var WantDesk

Function .onInit
  SetShellVarContext current
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\${APPNAME}"   ; fixed location (no /D override)
  ${IfNot} ${Silent}
    MessageBox MB_OKCANCEL|MB_ICONQUESTION "Install ${APPNAME} for this user?$\n$\nIt goes in the Start menu and starts with Windows (you can turn that off: unlock, right-click a panel > Start with Windows)." IDOK +2
    Abort
  ${EndIf}
  StrCpy $WantDesk 0
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/DESKTOP" $1
  ${IfNot} ${Errors}
    StrCpy $WantDesk 1
  ${ElseIfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "Also put a shortcut on the desktop?" IDNO +2
    StrCpy $WantDesk 1
  ${EndIf}
FunctionEnd

Function Fail   ; $R9 = message. Leaves the current install as it was.
  DetailPrint "$R9"
  !ifdef DEBUGLOG
  FileOpen $9 "$TEMP\bl-debug.txt" a
  FileWrite $9 "$R9$\r$\n"
  FileClose $9
  !endif
  MessageBox MB_OK|MB_ICONSTOP "$R9" /SD IDOK
  SetErrorLevel 1
  Quit
FunctionEnd

Section "Install"
  SetShellVarContext current
  InitPluginsDir
  ; Stop only a launcher started from this install folder (powershell.exe ... <dest>\Launcher.ps1), like the IExpress installer.
  System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$INSTDIR")i'
  nsExec::ExecToLog `${PS} "& {${STOP_LAUNCHER}}"`
  Pop $0
  Sleep 500
  ; Staged swap (R6-L1): copy the current install beside it, add the new files there, check, then swap folders.
  System::Call 'kernel32::GetTickCount()i.r1'
  StrCpy $Stage "$INSTDIR.new-$1"
  StrCpy $Old "$INSTDIR.old-$1"
  StrCpy $Keep "$PLUGINSDIR\keep"
  CreateDirectory "$LOCALAPPDATA\Programs"
  CreateDirectory "$Stage"
  ${If} ${FileExists} "$INSTDIR\*.*"
    ClearErrors
    CopyFiles /SILENT "$INSTDIR\*.*" "$Stage"
    ${If} ${Errors}
      RMDir /r "$Stage"
      StrCpy $R9 "${APPNAME} could not be updated: copying the current install failed.$\n$\nYour current install was not changed."
      Call Fail
    ${EndIf}
    ; Pictures: a picture is replaced only if it is still byte-for-byte one we shipped; others are set aside and put back.
    File "/oname=$PLUGINSDIR\known-pictures.txt" "${KNOWN}"
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$Stage")i'
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_KEEP", t "$Keep")i'
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_KNOWN", t "$PLUGINSDIR\known-pictures.txt")i'
    SetOutPath "$TEMP"
    nsExec::ExecToLog `${PS} "& {${PICS_SAVE}}"`
    Pop $0
  ${EndIf}
  Delete "$Stage\Uninstall.ps1"                 ; older IExpress uninstaller; Uninstall.exe replaces it
  ClearErrors
  SetOutPath "$Stage"
  SetOverwrite on
  !insertmacro PAYLOAD_FILES
  ${If} ${Errors}
    SetOutPath "$TEMP"
    RMDir /r "$Stage"
    StrCpy $R9 "${APPNAME} could not be installed: unpacking the files failed.$\n$\nNothing was added to the Start menu or the registry. Your current install was not changed."
    Call Fail
  ${EndIf}
  System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$Stage")i'
  SetOutPath "$TEMP"                            ; child cwd must not be the stage, or the swap rename fails
  nsExec::ExecToLog `${PS} "& {${PICS_RESTORE}}"`
  Pop $0
  ${IfNot} ${FileExists} "$Stage\buttons.json"
    CopyFiles /SILENT "$Stage\buttons.default.json" "$Stage\buttons.json"   ; first install only (R-M2)
  ${EndIf}
  WriteUninstaller "$Stage\Uninstall.exe"
  ${IfNot} ${FileExists} "$Stage\Launcher.ps1"
  ${OrIfNot} ${FileExists} "$Stage\ButtonLauncher.exe"
  ${OrIfNot} ${FileExists} "$Stage\buttons.default.json"
  ${OrIfNot} ${FileExists} "$Stage\Uninstall.exe"
    SetOutPath "$TEMP"
    RMDir /r "$Stage"
    StrCpy $R9 "${APPNAME} could not be installed: core files are missing after unpacking.$\n$\nNothing was added to the Start menu or the registry. Your current install was not changed."
    Call Fail
  ${EndIf}
  SetOutPath "$TEMP"
  StrCpy $2 0                                   ; 1 = an old install was moved aside
  ${If} ${FileExists} "$INSTDIR\*.*"
    ClearErrors
    Rename "$INSTDIR" "$Old"
    ${If} ${Errors}
      RMDir /r "$Stage"
      StrCpy $R9 "${APPNAME} could not be updated (a file may be in use). Your current install was not changed."
      Call Fail
    ${EndIf}
    StrCpy $2 1
  ${EndIf}
  ClearErrors
  Rename "$Stage" "$INSTDIR"
  ${If} ${Errors}
    ${If} $2 = 1
      ClearErrors
      Rename "$Old" "$INSTDIR"
      ${If} ${Errors}   ; both failed: delete nothing, say where everything is (R7-L2)
        StrCpy $R9 "${APPNAME} could not be updated, and the old install could not be put back automatically.$\n$\nNothing was deleted:$\nOld install: $Old$\nNew files: $Stage$\n$\nRename the old folder back to:$\n$INSTDIR$\nor run this installer again."
        Call Fail
      ${EndIf}
    ${EndIf}
    RMDir /r "$Stage"
    StrCpy $R9 "${APPNAME} could not be updated (a file may be in use). Your current install was not changed."
    Call Fail
  ${EndIf}
  ${If} $2 = 1
    RMDir /r "$Old"
  ${EndIf}
  SetOutPath "$INSTDIR"

  ; Shortcuts (per-user Start menu, same names as the IExpress installer)
  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\ButtonLauncher.exe" "" "$INSTDIR\ButtonLauncher.exe" 0 SW_SHOWNORMAL "" "${APPNAME}"
  CreateShortcut "$SMPROGRAMS\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\ButtonLauncher.exe" 0 SW_SHOWNORMAL "" "Uninstall ${APPNAME}"
  ${If} $WantDesk = 1
    CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\ButtonLauncher.exe" "" "$INSTDIR\ButtonLauncher.exe" 0 SW_SHOWNORMAL "" "${APPNAME}"
  ${Else}
    Delete "$DESKTOP\${APPNAME}.lnk"
  ${EndIf}
  Delete "$SMSTARTUP\${APPNAME}.lnk"            ; older builds used the Startup folder

  ; Start with Windows: HKCU Run, ON by default (/NOAUTOSTART turns it off, like -NoAutostart)
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/NOAUTOSTART" $1
  ${If} ${Errors}
    WriteRegStr HKCU "${RUNKEY}" "${KEYNAME}" '"$INSTDIR\ButtonLauncher.exe"'
  ${Else}
    DeleteRegValue HKCU "${RUNKEY}" "${KEYNAME}"
  ${EndIf}

  ; Installed apps entry; drop an older 'Launcher' key only if it points at this folder
  ReadRegStr $1 HKCU "${UNKEY}\${APPNAME}" "InstallLocation"
  ${If} $1 == "$INSTDIR"
  ${OrIf} $1 == "$INSTDIR\"
    DeleteRegKey HKCU "${UNKEY}\${APPNAME}"
  ${EndIf}
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "Publisher" "Charles Cipolla"
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "DisplayIcon" "$INSTDIR\ButtonLauncher.exe,0"
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNKEY}\${KEYNAME}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNKEY}\${KEYNAME}" "NoModify" 1
  WriteRegDWORD HKCU "${UNKEY}\${KEYNAME}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $1 $3 $4
  IntFmt $1 "0x%08X" $1
  WriteRegDWORD HKCU "${UNKEY}\${KEYNAME}" "EstimatedSize" $1

  Exec '"$INSTDIR\ButtonLauncher.exe"'
  ${If} $WantDesk = 1
    StrCpy $1 "the Start menu and the desktop"
  ${Else}
    StrCpy $1 "the Start menu"
  ${EndIf}
  MessageBox MB_OK "${APPNAME} is installed.$\nFind it in $1 (type its name in Windows search).$\nUninstall from Settings > Apps." /SD IDOK
SectionEnd

Function un.onInit
  SetShellVarContext current
  ; Refuse unless this is exactly %LOCALAPPDATA%\Programs\Launcher with Launcher.ps1 in it (same guard as Uninstall.ps1)
  ${If} "$INSTDIR" != "$LOCALAPPDATA\Programs\${APPNAME}"
  ${OrIfNot} ${FileExists} "$INSTDIR\Launcher.ps1"
    MessageBox MB_OK "Uninstall stopped: this doesn't look like the ${APPNAME} install folder.$\n$INSTDIR" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  ${IfNot} ${Silent}
    MessageBox MB_YESNO "Remove ${APPNAME}?" IDYES +2
    Quit
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$INSTDIR")i'
  nsExec::ExecToLog `${PS} "& {${STOP_LAUNCHER}}"`
  Pop $0
  Sleep 500
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  Delete "$SMSTARTUP\${APPNAME}.lnk"
  Delete "$SMPROGRAMS\Uninstall ${APPNAME}.lnk"
  DeleteRegKey HKCU "${UNKEY}\${KEYNAME}"
  ReadRegStr $1 HKCU "${UNKEY}\${APPNAME}" "InstallLocation"
  ${If} $1 == "$INSTDIR"
  ${OrIf} $1 == "$INSTDIR\"
    DeleteRegKey HKCU "${UNKEY}\${APPNAME}"
  ${EndIf}
  ; Run value: only if it starts this folder's exe (or the old .vbs), exact command (LJ-N6)
  ReadRegStr $1 HKCU "${RUNKEY}" "${KEYNAME}"
  ${If} $1 == '"$INSTDIR\ButtonLauncher.exe"'
  ${OrIf} $1 == 'wscript.exe "$INSTDIR\Start Launcher.vbs"'
    DeleteRegValue HKCU "${RUNKEY}" "${KEYNAME}"
  ${EndIf}
  ; Same as the IExpress uninstaller: the whole folder goes, including buttons.json and pictures.
  SetOutPath "$TEMP"
  RMDir /r "$INSTDIR"
SectionEnd
