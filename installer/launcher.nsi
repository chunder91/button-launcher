; Button Launcher per-user installer (NSIS). Built on Linux by tools/build-nsis.sh; do not build by hand.
; Mirrors Build-Installer.ps1's IExpress install script: per-user, %LOCALAPPDATA%\Programs\Launcher, HKCU Run value
; "ButtonLauncher" ON by default, Start menu shortcuts, HKCU Uninstall\ButtonLauncher, staged swap, keeps buttons.json
; and user-changed pictures. No network access. The PowerShell one-liners come from installer/*.ps1 via generated.nsh.
Unicode true
ManifestDPIAware true
RequestExecutionLevel user
XPStyle on                      ; themed (Win11) buttons and progress bar
SetCompressor /SOLID lzma
!include LogicLib.nsh
!include FileFunc.nsh
!include generated.nsh          ; VERSION, SRC, PAYLOAD_FILES macro, PICS_SAVE, PICS_RESTORE, STOP_LAUNCHER

!define APPNAME "Launcher"
!define KEYNAME "ButtonLauncher"
!define UNKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall"
!define RUNKEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define PS `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command`

Name "${APPNAME}"
OutFile "${OUTFILE}"
Icon "${SRC}\images\app.ico"
UninstallIcon "${SRC}\images\app.ico"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
ShowInstDetails hide            ; the log stays under "Show details"
ShowUninstDetails hide
AutoCloseWindow true            ; the success box is the last step
BrandingText "${APPNAME} ${VERSION}"
InstallColors /windows          ; system text on window background in the log
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Charles Cipolla"
VIAddVersionKey "FileDescription" "${APPNAME} Setup"
VIAddVersionKey "LegalCopyright" "Charles Cipolla"
Page instfiles
UninstPage instfiles


; NSIS RMDir /r recurses into every directory entry without checking FILE_ATTRIBUTE_REPARSE_POINT (Source/exehead/util.c
; myDelete), and CopyFiles is SHFileOperation, which copies through links. So: never copy an install that has links,
; and unlink every link (the link only) before any RMDir /r. $R7 = "count" or "unlink"; $R8 += links found.
!macro WALKLINKS un
Function ${un}WalkLinks
  Exch $0
  Push $1
  Push $2
  Push $3
  Push $4
  ClearErrors
  FindFirst $1 $2 "$0\*.*"
  loop:
    StrCmp $2 "" done
    StrCmp $2 "." next
    StrCmp $2 ".." next
    System::Call 'kernel32::GetFileAttributesW(w "$0\$2")i.r3'
    ${If} $3 = -1
      IntOp $R8 $R8 + 1          ; unreadable entry: treat as unsafe
      Goto next
    ${EndIf}
    IntOp $4 $3 & 0x400
    ${If} $4 <> 0
      IntOp $R8 $R8 + 1
      ${If} $R7 == "unlink"
        IntOp $4 $3 & 0x10
        ${If} $4 <> 0
          RMDir "$0\$2"            ; RemoveDirectory on a junction/dir symlink removes the link, not the target
        ${Else}
          Delete "$0\$2"           ; a file symlink is deleted as-is
        ${EndIf}
      ${EndIf}
    ${Else}
      IntOp $4 $3 & 0x10
      ${If} $4 <> 0
        Push "$0\$2"
        Call ${un}WalkLinks
      ${EndIf}
    ${EndIf}
  next:
    FindNext $1 $2
    Goto loop
  done:
  FindClose $1
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd
; $R6 = dir. Sets $R5 = 1 if the dir itself is a link.
Function ${un}IsLink
  StrCpy $R5 0
  System::Call 'kernel32::GetFileAttributesW(w "$R6")i.r9'
  ${If} $9 <> -1
    IntOp $9 $9 & 0x400
    ${If} $9 <> 0
      StrCpy $R5 1
    ${EndIf}
  ${EndIf}
FunctionEnd
!macroend
!insertmacro WALKLINKS ""
!insertmacro WALKLINKS "un."

; Remove a folder tree without following links: refuse a link root, unlink inner links, re-check, then RMDir /r.
!macro SAFE_RMDIR un dir
  StrCpy $R6 "${dir}"
  Call ${un}IsLink
  ${If} $R5 = 1
    RMDir "${dir}"
  ${Else}
    StrCpy $R7 "unlink"
    StrCpy $R8 0
    Push "${dir}"
    Call ${un}WalkLinks
    StrCpy $R7 "count"
    StrCpy $R8 0
    Push "${dir}"
    Call ${un}WalkLinks
    StrCpy $R6 "${dir}"
    Call ${un}IsLink                 ; R13-L1: re-check the root right before RMDir /r
    ${If} $R8 = 0
    ${AndIf} $R5 = 0
      RMDir /r "${dir}"
    ${Else}
      SetDetailsPrint listonly       ; status line: 40 chars or fewer
      DetailPrint "Not removed (links left inside): ${dir}"
    ${EndIf}
  ${EndIf}
!macroend

Var Stage
Var Old
Var Keep
Var WantDesk
Var IsUpdate                    ; 1 = an existing Launcher install is being updated
Var ShortDir                    ; $INSTDIR for messages, shortened to AppData\Local\... when it is under the profile
Var NoReopen                    ; 1 = Fail must not reopen (a file was in use, so Launcher may still be running)
Var Elevated                    ; 1 = Setup runs elevated (M24-L1): never start Launcher from here, it would run as admin
Var FailShort                   ; status-line text for Fail (40 chars or fewer)

Function .onInit
  SetShellVarContext current
  ${If} "$LOCALAPPDATA" == ""
    MessageBox MB_OK|MB_ICONSTOP "Setup stopped: this account has no local application data folder." /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\${APPNAME}"   ; fixed location (no /D override)
  StrCpy $ShortDir "$INSTDIR"
  ${If} "$LOCALAPPDATA" == "$PROFILE\AppData\Local"
    StrCpy $ShortDir "AppData\Local\Programs\${APPNAME}"
  ${EndIf}
  StrCpy $FailShort "Setup stopped. Nothing was changed."
  StrCpy $NoReopen 0
  StrCpy $Elevated 0                            ; M24-L1: detect only; an elevated install is not refused
  System::Call 'shell32::IsUserAnAdmin()i.r0'
  ${If} $0 <> 0
    StrCpy $Elevated 1
  ${EndIf}
  ; N4: an EMPTY leftover Programs\Launcher (no files, no links, not itself a link) counts as a fresh install
  ${If} ${FileExists} "$INSTDIR\*.*"
  ${AndIfNot} ${FileExists} "$INSTDIR\Launcher.ps1"
  ${AndIfNot} ${FileExists} "$INSTDIR\.buttonlauncher"
    StrCpy $R6 "$INSTDIR"
    Call IsLink
    StrCpy $3 0
    FindFirst $1 $2 "$INSTDIR\*.*"
    ${DoWhile} $2 != ""
      ${If} $2 != "."
      ${AndIf} $2 != ".."
        IntOp $3 $3 + 1
      ${EndIf}
      FindNext $1 $2
    ${Loop}
    FindClose $1
    ${If} $R5 = 0
    ${AndIf} $3 = 0
      RMDir "$INSTDIR"                          ; non-recursive: only an empty folder can go
    ${EndIf}
  ${EndIf}
  ; R14-L3: never merge into some other app's Programs\Launcher
  ${If} ${FileExists} "$INSTDIR\*.*"
  ${AndIfNot} ${FileExists} "$INSTDIR\Launcher.ps1"
  ${AndIfNot} ${FileExists} "$INSTDIR\.buttonlauncher"
    MessageBox MB_OK|MB_ICONSTOP "Setup stopped. A folder named ${APPNAME} is already here, and it doesn't look like ours:$\n$\n$ShortDir$\n$\nIt may belong to another program, so Setup left it alone. Nothing was changed. Ask your IT contact for help." /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  ; UX-4: refuse before any question if the install is missing but a Launcher.old-*/.new-* folder exists (R15-H1)
  ${IfNot} ${FileExists} "$INSTDIR\*.*"
    Call FindLeftover
    ${If} $4 != ""
      MessageBox MB_OK|MB_ICONSTOP "${APPNAME} can't be installed yet.$\n$\nA copy of your earlier ${APPNAME} was found here:$\n$\n$4$\n$\nIt may hold your buttons, so Setup left it alone. Nothing was changed.$\n$\nAsk your IT contact to rename that folder to $\"${APPNAME}$\", then run Setup again." /SD IDOK
      SetErrorLevel 1
      Quit
    ${EndIf}
  ${EndIf}
  StrCpy $IsUpdate 0
  ${If} ${FileExists} "$INSTDIR\Launcher.ps1"
  ${OrIf} ${FileExists} "$INSTDIR\.buttonlauncher"
    StrCpy $IsUpdate 1
  ${EndIf}
  ${IfNot} ${Silent}
    ${If} $IsUpdate = 1
      MessageBox MB_OKCANCEL|MB_ICONQUESTION "Update ${APPNAME} to ${VERSION}?$\n$\nYour buttons and pictures are kept. ${APPNAME} closes for a moment and opens again when the update is done." IDOK +2
      Abort
    ${Else}
      MessageBox MB_OKCANCEL|MB_ICONQUESTION "Install ${APPNAME} for this Windows user?$\n$\nIt will be added to the Start menu and will open each time you sign in. You can turn that off later from ${APPNAME}'s right-click menu." IDOK +2
      Abort
    ${EndIf}
  ${EndIf}
  StrCpy $WantDesk 0
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/DESKTOP" $1
  ${IfNot} ${Errors}
    StrCpy $WantDesk 1
  ${ElseIf} $IsUpdate = 1
    ; UX-5: an update keeps whatever desktop shortcut is there and does not ask
  ${ElseIfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "Also put a shortcut on the desktop?" IDNO +2
    StrCpy $WantDesk 1
  ${EndIf}
FunctionEnd

; $4 = shortened path of the first Launcher.old-* (else .new-*) folder beside the install, or "" if none.
Function FindLeftover
  FindFirst $3 $4 "$INSTDIR.old-*"
  ${If} $4 == ""
    FindClose $3
    FindFirst $3 $4 "$INSTDIR.new-*"
  ${EndIf}
  FindClose $3
  ${If} $4 != ""
    ${If} "$ShortDir" != "$INSTDIR"
      StrCpy $4 "AppData\Local\Programs\$4"
    ${Else}
      StrCpy $4 "$LOCALAPPDATA\Programs\$4"
    ${EndIf}
  ${EndIf}
FunctionEnd

;; R15-L1: after a failure that left the install untouched, drop the new pictures backup if the install's pictures are there;
;; otherwise keep it and say where. KeepNote only appends the location.
Function DropKeep
  ${If} $5 = 1
    ${If} ${FileExists} "$INSTDIR\images\*.*"
      !insertmacro SAFE_RMDIR "" "$Keep"
    ${Else}
      Call KeepNote
    ${EndIf}
  ${EndIf}
FunctionEnd
Function KeepNote
  ${If} $5 = 1
  ${AndIf} ${FileExists} "$Keep\*.*"
    StrCpy $R9 "$R9$\n$\nA copy of your changed pictures is kept in:$\n$Keep"
  ${EndIf}
FunctionEnd

Function Fail   ; $R9 = message. Leaves the current install as it was.
  ; UX-2: Setup closed the running launcher; on an update, open the (unchanged) install again.
  ${If} $IsUpdate = 1
  ${AndIf} $NoReopen = 0
  ${AndIf} $Elevated = 0
  ${AndIf} ${FileExists} "$INSTDIR\ButtonLauncher.exe"
    SetDetailsPrint listonly                    ; UI: keep "Execute: ..." out of the header
    Exec '"$INSTDIR\ButtonLauncher.exe"'
    StrCpy $R9 "$R9$\n$\n${APPNAME} has been opened again, so you can keep using it."
  ${EndIf}
  ; UI-1: the full text goes to the log and the box; the header status line gets 40 chars or fewer.
  SetDetailsPrint listonly
  DetailPrint "$R9"
  SetDetailsPrint textonly
  DetailPrint "$FailShort"
  SetDetailsPrint listonly
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
  SetDetailsPrint textonly                      ; UI-1: one short status line; every step goes to the hidden log only
  DetailPrint "Installing ${APPNAME}..."
  SetDetailsPrint listonly
  InitPluginsDir
  ; Stop only a launcher started from this install folder (powershell.exe ... <dest>\Launcher.ps1), like the IExpress installer.
  System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$INSTDIR")i'
  nsExec::ExecToLog `${PS} "& {${STOP_LAUNCHER}}"`
  Pop $0
  Sleep 500
  ; Staged swap (R6-L1): copy the current install beside it, add the new files there, check, then swap folders.
  ; N2/R14-I1: folder suffix = local time + 4 hex digits (tick xor pid); refuse if any of the three names exists
  ${GetTime} "" "L" $R0 $R1 $R2 $R3 $R4 $R5 $R6
  System::Call 'kernel32::GetTickCount()i.r6'
  System::Call 'kernel32::GetCurrentProcessId()i.r7'
  IntOp $6 $6 ^ $7
  IntOp $6 $6 & 0xFFFF
  IntFmt $6 "%04x" $6
  StrCpy $1 "$R2$R1$R0-$R4$R5$R6-$6"
  StrCpy $Stage "$INSTDIR.new-$1"
  StrCpy $Old "$INSTDIR.old-$1"
  StrCpy $Keep "$INSTDIR.pictures-backup-$1"   ; beside the install, so a failed restore never loses pictures (R14-M1)
  StrCpy $5 0                                 ; 1 = pictures were set aside in $Keep
  CreateDirectory "$LOCALAPPDATA\Programs"
  ${If} ${FileExists} "$Stage\*.*"
  ${OrIf} ${FileExists} "$Old\*.*"
  ${OrIf} ${FileExists} "$Keep\*.*"
    StrCpy $R9 "${APPNAME} could not be installed: a working folder name is already taken ($1). Nothing was changed. Run Setup again."
    Call Fail
  ${EndIf}
  ; R15-H1: never auto-delete Launcher.old-*/.new-*. If the install is missing but one exists, it may be the user's only copy.
  ${IfNot} ${FileExists} "$INSTDIR\*.*"
    Call FindLeftover                           ; also checked in .onInit; kept here in case one appeared since
    ${If} $4 != ""
      StrCpy $R9 "${APPNAME} can't be installed yet.$\n$\nA copy of your earlier ${APPNAME} was found here:$\n$\n$4$\n$\nIt may hold your buttons, so Setup left it alone. Nothing was changed.$\n$\nAsk your IT contact to rename that folder to $\"${APPNAME}$\", then run Setup again."
      Call Fail
    ${EndIf}
  ${EndIf}
  CreateDirectory "$Stage"
  ${If} ${FileExists} "$INSTDIR\*.*"
    StrCpy $R6 "$INSTDIR"
    Call IsLink
    StrCpy $R7 "count"
    StrCpy $R8 0
    ${If} $R5 = 0
      Push "$INSTDIR"
      Call WalkLinks
    ${EndIf}
    ${If} $R5 = 1
    ${OrIf} $R8 > 0
      RMDir "$Stage"
      StrCpy $NoReopen 1                        ; M24-I1: never start an exe from a linked install folder
      StrCpy $R9 "${APPNAME} could not be updated: the install folder is, or contains a shortcut-style link, and links are never copied or followed.$\n$\n$ShortDir$\n$\nYour current install was not changed. Ask your IT contact for help."
      Call Fail
    ${EndIf}
    ClearErrors
    CopyFiles /SILENT "$INSTDIR\*.*" "$Stage"
    ${If} ${Errors}
      !insertmacro SAFE_RMDIR "" "$Stage"
      StrCpy $R9 "${APPNAME} could not be updated: copying the current install failed.$\n$\nYour current install was not changed."
      Call Fail
    ${EndIf}
    ; Pictures: a picture is replaced only if it is still byte-for-byte one we shipped; others are set aside and put back.
    File "/oname=$PLUGINSDIR\known-pictures.txt" "${KNOWN}"
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$Stage")i'
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_KEEP", t "$Keep")i'
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_KNOWN", t "$PLUGINSDIR\known-pictures.txt")i'
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_OK", t "$PLUGINSDIR\saved.ok")i'
    SetOutPath "$TEMP"
    nsExec::ExecToLog `${PS} "& {${PICS_SAVE}}"`
    Pop $0
    ; R14-M1: proceed only on exit 0 AND the success file the script writes last (a stub or blocked PowerShell writes neither)
    ${If} $0 S!= "0"                            ; N1: "error"/"timeout" are failures too
    ${OrIfNot} ${FileExists} "$PLUGINSDIR\saved.ok"
      !insertmacro SAFE_RMDIR "" "$Stage"
      !insertmacro SAFE_RMDIR "" "$Keep"
      StrCpy $R9 "${APPNAME} could not be updated.$\n$\nSetup checks your own pictures before an update so none are lost, and that check didn't finish (code $0). Nothing was changed.$\n$\nRestart the PC and run Setup again. If you see this again, send a photo of this message to your IT contact."
      Call Fail
    ${EndIf}
    StrCpy $5 1
    StrCpy $R6 "$Keep"
    Call IsLink
    ${If} $R5 = 1
      !insertmacro SAFE_RMDIR "" "$Stage"
      StrCpy $R9 "${APPNAME} could not be updated: the pictures backup folder is a link:$\n$\n$Keep$\n$\nYour current install was not changed."
      Call Fail
    ${EndIf}
  ${EndIf}
  Delete "$Stage\Uninstall.ps1"                 ; older IExpress uninstaller; Uninstall.exe replaces it
  ClearErrors
  SetOutPath "$Stage"
  SetOverwrite on
  !insertmacro PAYLOAD_FILES
  ${If} ${Errors}
    SetOutPath "$TEMP"
    !insertmacro SAFE_RMDIR "" "$Stage"
    StrCpy $R9 "${APPNAME} could not be installed: unpacking the files failed.$\n$\nNothing was added to the Start menu or the registry. Your current install was not changed."
    Call DropKeep
    Call Fail
  ${EndIf}
  FileOpen $9 "$Stage\.buttonlauncher" w     ; R14-L3 marker
  FileWrite $9 "Button Launcher ${VERSION}$\r$\n"
  FileClose $9
  ${If} $5 = 1
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$Stage")i'
    System::Call 'kernel32::SetEnvironmentVariable(t "BL_OK", t "$PLUGINSDIR\restored.ok")i'
    SetOutPath "$TEMP"                          ; child cwd must not be the stage, or the swap rename fails
    nsExec::ExecToLog `${PS} "& {${PICS_RESTORE}}"`
    Pop $0
    ${If} $0 S!= "0"
    ${OrIfNot} ${FileExists} "$PLUGINSDIR\restored.ok"
      !insertmacro SAFE_RMDIR "" "$Stage"
      StrCpy $R9 "${APPNAME} could not be updated: putting your pictures back failed ($0).$\n$\nYour current install was not changed. A copy of your changed pictures is kept in:$\n$Keep"
      Call Fail
    ${EndIf}
  ${EndIf}
  ${IfNot} ${FileExists} "$Stage\buttons.json"
    CopyFiles /SILENT "$Stage\buttons.default.json" "$Stage\buttons.json"   ; first install only (R-M2)
  ${EndIf}
  WriteUninstaller "$Stage\Uninstall.exe"
  ${IfNot} ${FileExists} "$Stage\Launcher.ps1"
  ${OrIfNot} ${FileExists} "$Stage\ButtonLauncher.exe"
  ${OrIfNot} ${FileExists} "$Stage\buttons.default.json"
  ${OrIfNot} ${FileExists} "$Stage\Uninstall.exe"
    SetOutPath "$TEMP"
    !insertmacro SAFE_RMDIR "" "$Stage"
    StrCpy $R9 "${APPNAME} could not be installed: core files are missing after unpacking.$\n$\nNothing was added to the Start menu or the registry. Your current install was not changed."
    Call DropKeep
    Call Fail
  ${EndIf}
  SetOutPath "$TEMP"
  StrCpy $2 0                                   ; 1 = an old install was moved aside
  ${If} ${FileExists} "$INSTDIR\*.*"
    ClearErrors
    Rename "$INSTDIR" "$Old"
    ${If} ${Errors}
      !insertmacro SAFE_RMDIR "" "$Stage"
      StrCpy $NoReopen 1                          ; file in use: Launcher may still run; never start a second copy
      StrCpy $R9 "${APPNAME} could not be updated (a file may be in use). Your current install was not changed."
      Call DropKeep
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
        StrCpy $FailShort "Setup stopped. Nothing was deleted."
        StrCpy $R9 "${APPNAME} could not be updated, and the old install could not be put back automatically.$\n$\nNothing was deleted:$\nOld install: $Old$\nNew files: $Stage$\n$\nRename the old folder back to:$\n$INSTDIR$\nbefore running Setup again (Setup will refuse until you do)."
        Call KeepNote
        Call Fail
      ${EndIf}
    ${EndIf}
    !insertmacro SAFE_RMDIR "" "$Stage"
    StrCpy $NoReopen 1                          ; file in use: Launcher may still run; never start a second copy
    StrCpy $R9 "${APPNAME} could not be updated (a file may be in use). Your current install was not changed."
    Call DropKeep
    Call Fail
  ${EndIf}
  ${If} $2 = 1
    !insertmacro SAFE_RMDIR "" "$Old"
  ${EndIf}
  ${If} $5 = 1
    !insertmacro SAFE_RMDIR "" "$Keep"          ; pictures are in the new install now
  ${EndIf}
  SetOutPath "$INSTDIR"

  ; Shortcuts (per-user Start menu, same names as the IExpress installer)
  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\ButtonLauncher.exe" "" "$INSTDIR\ButtonLauncher.exe" 0 SW_SHOWNORMAL "" "${APPNAME}"
  CreateShortcut "$SMPROGRAMS\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\ButtonLauncher.exe" 0 SW_SHOWNORMAL "" "Uninstall ${APPNAME}"
  ${If} $WantDesk = 1
    CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\ButtonLauncher.exe" "" "$INSTDIR\ButtonLauncher.exe" 0 SW_SHOWNORMAL "" "${APPNAME}"
  ${ElseIf} $IsUpdate = 0
    Delete "$DESKTOP\${APPNAME}.lnk"
  ${EndIf}                                      ; UX-5: an update keeps the desktop shortcut as it was
  Delete "$SMSTARTUP\${APPNAME}.lnk"            ; older builds used the Startup folder

  ; Start with Windows: HKCU Run, ON by default (/NOAUTOSTART turns it off, like -NoAutostart)
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/NOAUTOSTART" $1
  ${If} ${Errors}
    ; UX-5: an update re-writes the Run value only if it is still there (the user may have turned it off)
    ClearErrors
    ReadRegStr $1 HKCU "${RUNKEY}" "${KEYNAME}"
    ${If} $IsUpdate = 0
    ${OrIfNot} ${Errors}
      WriteRegStr HKCU "${RUNKEY}" "${KEYNAME}" '"$INSTDIR\ButtonLauncher.exe"'
    ${EndIf}
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

  ${If} $IsUpdate = 1
    StrCpy $1 "updated"
  ${Else}
    StrCpy $1 "installed"
  ${EndIf}
  ${If} $Elevated = 0
    SetDetailsPrint listonly                    ; UI: keep "Execute: ..." out of the header
    Exec '"$INSTDIR\ButtonLauncher.exe"'
  ${EndIf}
  SetDetailsPrint textonly
  DetailPrint "${APPNAME} is $1."
  SetDetailsPrint listonly
  ${If} $Elevated = 0
    MessageBox MB_OK|MB_ICONINFORMATION "${APPNAME} is $1 and open now.$\n$\nTo open it later: click Start and type ${APPNAME}.$\n$\nTo remove it: Settings > Apps." /SD IDOK
  ${Else}
    MessageBox MB_OK|MB_ICONINFORMATION "${APPNAME} is $1.$\n$\nTo open it: click Start and type ${APPNAME}.$\n$\nTo remove it: Settings > Apps." /SD IDOK
  ${EndIf}
SectionEnd

Function un.onInit
  SetShellVarContext current
  ; Refuse unless this is exactly %LOCALAPPDATA%\Programs\Launcher with Launcher.ps1 in it (same guard as Uninstall.ps1)
  StrCpy $0 0
  ${If} ${FileExists} "$INSTDIR\Launcher.ps1"
  ${OrIf} ${FileExists} "$INSTDIR\.buttonlauncher"
    StrCpy $0 1
  ${EndIf}
  ${If} "$LOCALAPPDATA" == ""
  ${OrIf} "$INSTDIR" != "$LOCALAPPDATA\Programs\${APPNAME}"
  ${OrIf} $0 = 0
    MessageBox MB_OK|MB_ICONSTOP "Uninstall stopped: this doesn't look like the ${APPNAME} install folder:$\n$\n$INSTDIR$\n$\nNothing was removed. Ask your IT contact for help." /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  StrCpy $R6 "$INSTDIR"
  Call un.IsLink
  ${If} $R5 = 1
    MessageBox MB_OK|MB_ICONSTOP "Uninstall stopped: the install folder is a shortcut-style link, so nothing was removed:$\n$\n$INSTDIR$\n$\nAsk your IT contact for help." /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  ${IfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON2 "Remove ${APPNAME} for this Windows user?$\n$\nThis also deletes your buttons and any pictures you added. They can't be brought back.$\n$\nTo keep them, choose No." IDYES +2
    Quit
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  SetDetailsPrint textonly
  DetailPrint "Removing ${APPNAME}..."
  SetDetailsPrint listonly
  System::Call 'kernel32::SetEnvironmentVariable(t "BL_DIR", t "$INSTDIR")i'
  nsExec::ExecToLog `${PS} "& {${STOP_LAUNCHER}}"`
  Pop $0
  Sleep 500
  ; Links first: unlink them, and if any is left, stop before touching shortcuts, registry or files.
  StrCpy $R7 "unlink"
  StrCpy $R8 0
  Push "$INSTDIR"
  Call un.WalkLinks
  StrCpy $R7 "count"
  StrCpy $R8 0
  Push "$INSTDIR"
  Call un.WalkLinks
  ${If} $R8 > 0
    MessageBox MB_OK|MB_ICONSTOP "Uninstall stopped: the install folder contains a shortcut-style link that could not be removed safely, so nothing was removed:$\n$\n$INSTDIR$\n$\nAsk your IT contact for help." /SD IDOK
    SetErrorLevel 2
    Quit
  ${EndIf}
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
  ; v1.4.0 (M14-I3): this Windows user's email count login. Only these files; the folder only if it is then empty.
  StrCpy $R6 "$LOCALAPPDATA\ButtonLauncher"
  Call un.IsLink                                       ; M15-I2: never through a junction or symlink
  ${If} $R5 = 0
    Delete "$LOCALAPPDATA\ButtonLauncher\email-count.json"
    Delete "$LOCALAPPDATA\ButtonLauncher\email-count.dat"
    Delete "$LOCALAPPDATA\ButtonLauncher\email-count.json.tmp"
    Delete "$LOCALAPPDATA\ButtonLauncher\email-count.dat.tmp"
    RMDir "$LOCALAPPDATA\ButtonLauncher"               ; non-recursive: stays if anything else is in it
  ${Else}
    SetDetailsPrint listonly
    DetailPrint "Not touched (it is a link): $LOCALAPPDATA\ButtonLauncher"
  ${EndIf}
  ; Same as the IExpress uninstaller: the whole folder goes, including buttons.json and pictures.
  SetOutPath "$TEMP"
  !insertmacro SAFE_RMDIR "un." "$INSTDIR"
  ${If} ${FileExists} "$INSTDIR\*.*"
    MessageBox MB_OK|MB_ICONEXCLAMATION "${APPNAME} was removed, but some files could not be deleted:$\n$\n$INSTDIR" /SD IDOK
  ${Else}
    MessageBox MB_OK|MB_ICONINFORMATION "${APPNAME} was removed for this Windows user." /SD IDOK
  ${EndIf}
  SetAutoClose true
SectionEnd
