#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

;;; Glass Curtain
;;; Keeps a wallpaper "curtain" directly behind every VS Code window (main window
;;; and popped-out windows), sized to that window, showing the slice of the
;;; wallpaper that belongs at that spot. Through a transparent theme it looks
;;; like the real desktop, but whatever apps are behind VS Code stay hidden.
;;; Wallpapers are read live from Windows (per monitor), so changing a
;;; wallpaper is picked up automatically.
;;; (CTRL + ALT + W) toggles it on/off.

; ===================== CONFIG =====================
TargetExe    := "Kiro.exe"         ; "Code.exe" for regular VS Code
CurtainColor := "0a0e14"           ; shown if a wallpaper can't be read
ToggleKey    := "^!w"              ; Ctrl+Alt+W
TickMs       := 16                 ; how often to re-sync windows (ms)
WallCheckMs  := 2000               ; how often to check for wallpaper changes (ms)
; ==================================================

; Work in physical pixels so positions line up on mixed-DPI monitors
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

global Curtains := Map()           ; Kiro hwnd -> curtain object
global ImgSizes := Map()           ; image path -> [w, h]
global Enabled  := true
global MonWalls := GetWallpapers() ; [{l,t,r,b,path}] per monitor
global WallPos  := GetWallpaperPosition()

Hotkey(ToggleKey, ToggleCurtains)
SetTimer(UpdateCurtains, TickMs)
SetTimer(RefreshWallpapers, WallCheckMs)

;;;;;;-------------------------------------------
ToggleCurtains(*) {
    global Enabled
    Enabled := !Enabled
    if Enabled {
        SetTimer(UpdateCurtains, TickMs)
    } else {
        SetTimer(UpdateCurtains, 0)
        for hwnd, c in Curtains
            c.gui.Destroy()
        Curtains.Clear()
    }
    ToolTip("glass curtain " (Enabled ? "on" : "off"))
    SetTimer(() => ToolTip(), -1000)
}

;;;;;;-------------------------------------------
; Re-read wallpapers; if anything changed, make every curtain reload
RefreshWallpapers() {
    global MonWalls, WallPos
    fresh := GetWallpapers()
    pos := GetWallpaperPosition()
    if (WallSignature(fresh) pos != WallSignature(MonWalls) WallPos) {
        MonWalls := fresh
        WallPos := pos
        ImgSizes.Clear()
        for hwnd, c in Curtains
            c.mon := ""            ; forces a reload on the next tick
    }
}

WallSignature(list) {
    s := ""
    for m in list
        s .= m.l "," m.t "," m.r "," m.b "," m.path "|"
    return s
}

;;;;;;-------------------------------------------
; Per-monitor wallpaper paths and rectangles, via IDesktopWallpaper
GetWallpapers() {
    list := []
    try {
        dw := ComObject("{C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD}"    ; CLSID DesktopWallpaper
                      , "{B92B56A9-8B55-4E14-9A89-0199BBB6F93B}")   ; IID IDesktopWallpaper
        count := 0
        ComCall(6, dw, "uint*", &count)                              ; GetMonitorDevicePathCount
        loop count {
            pId := 0, pPath := 0
            if ComCall(5, dw, "uint", A_Index - 1, "ptr*", &pId, "int") != 0   ; GetMonitorDevicePathAt
                continue
            rc := Buffer(16, 0)
            hrRect := ComCall(7, dw, "ptr", pId, "ptr", rc, "int")             ; GetMonitorRECT (fails if inactive)
            hrPath := ComCall(4, dw, "ptr", pId, "ptr*", &pPath, "int")        ; GetWallpaper
            path := (hrPath = 0 && pPath) ? StrGet(pPath, "UTF-16") : ""
            if pPath
                DllCall("ole32\CoTaskMemFree", "ptr", pPath)
            DllCall("ole32\CoTaskMemFree", "ptr", pId)
            if (hrRect = 0)
                list.Push({l: NumGet(rc, 0, "int"), t: NumGet(rc, 4, "int")
                         , r: NumGet(rc, 8, "int"), b: NumGet(rc, 12, "int"), path: path})
        }
    }
    return list
}

; 0=Center 1=Tile 2=Stretch 3=Fit 4=Fill 5=Span
GetWallpaperPosition() {
    pos := 4
    try {
        dw := ComObject("{C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD}"
                      , "{B92B56A9-8B55-4E14-9A89-0199BBB6F93B}")
        ComCall(11, dw, "int*", &pos)                                ; GetPosition
    }
    return pos
}

;;;;;;-------------------------------------------
UpdateCurtains() {
    seen := Map()
    for hwnd in WinGetList("ahk_exe " TargetExe) {
        if !IsMainWindow(hwnd)
            continue
        seen[hwnd] := true
        if !Curtains.Has(hwnd)
            Curtains[hwnd] := MakeCurtain()
        try SyncCurtain(hwnd, Curtains[hwnd])
    }
    ; remove curtains whose window is gone
    for hwnd, c in Curtains.Clone() {
        if !seen.Has(hwnd) {
            c.gui.Destroy()
            Curtains.Delete(hwnd)
        }
    }
}

;;;;;;-------------------------------------------
; Real VS Code windows only: skip menus, tooltips and tiny helper windows
IsMainWindow(hwnd) {
    try {
        if WinGetClass(hwnd) != "Chrome_WidgetWin_1"
            return false
        if WinGetExStyle(hwnd) & 0x80          ; WS_EX_TOOLWINDOW
            return false
        WinGetPos(, , &w, &h, hwnd)
        return (w > 300 && h > 200)
    } catch {
        return false
    }
}

;;;;;;-------------------------------------------
MakeCurtain() {
    ; no caption, no taskbar/alt-tab entry, never takes focus
    g := Gui("-Caption +ToolWindow -DPIScale +E0x08000000")
    g.BackColor := CurtainColor
    g.MarginX := 0, g.MarginY := 0
    pic := g.Add("Picture", "x0 y0 w1 h1")
    return {gui: g, pic: pic, mon: "", geo: "", rect: "", hidden: true}
}

;;;;;;-------------------------------------------
SyncCurtain(hwnd, c) {
    ; minimized -> hide its curtain
    if WinGetMinMax(hwnd) = -1 {
        if !c.hidden {
            c.gui.Hide()
            c.hidden := true
        }
        return
    }

    r := GetVisibleRect(hwnd)
    key := r.x "," r.y "," r.w "," r.h

    ; moved to a different monitor (or wallpaper changed) -> reload image
    mon := MonitorIndexAt(r.x + r.w // 2, r.y + r.h // 2)
    if (mon != c.mon) {
        c.mon := mon
        c.geo := WallpaperGeometry(mon)
        if (c.geo.path != "") {
            c.pic.Visible := true
            c.pic.Value := "*w" c.geo.w " *h" c.geo.h " " c.geo.path
        } else {
            c.pic.Visible := false
        }
        c.rect := ""
    }

    moved := (key != c.rect)
    if moved {
        c.rect := key
        ; slide the wallpaper so the visible slice matches the desktop
        if (c.geo.path != "")
            c.pic.Move(c.geo.x - r.x, c.geo.y - r.y, c.geo.w, c.geo.h)
    }

    if c.hidden {
        c.gui.Show("NA x" r.x " y" r.y " w" r.w " h" r.h)
        c.hidden := false
        moved := true
    }

    ; keep the curtain directly underneath this window
    below := DllCall("GetWindow", "ptr", hwnd, "uint", 2, "ptr")   ; GW_HWNDNEXT
    if (moved || below != c.gui.Hwnd)
        DllCall("SetWindowPos", "ptr", c.gui.Hwnd, "ptr", hwnd
            , "int", r.x, "int", r.y, "int", r.w, "int", r.h
            , "uint", 0x10 | 0x200)                                 ; NOACTIVATE | NOOWNERZORDER
}

;;;;;;-------------------------------------------
; Visible window bounds (excludes Windows' invisible resize border)
GetVisibleRect(hwnd) {
    rc := Buffer(16, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9, "ptr", rc, "uint", 16) = 0 {
        l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int")
        return {x: l, y: t, w: NumGet(rc, 8, "int") - l, h: NumGet(rc, 12, "int") - t}
    }
    WinGetPos(&x, &y, &w, &h, hwnd)
    return {x: x, y: y, w: w, h: h}
}

;;;;;;-------------------------------------------
; Which monitor (index into MonWalls) contains this point; 0 if none
MonitorIndexAt(x, y) {
    for i, m in MonWalls
        if (x >= m.l && x < m.r && y >= m.t && y < m.b)
            return i
    return 0
}

;;;;;;-------------------------------------------
; Where the wallpaper image sits on that monitor, honoring the Windows
; Fill / Fit / Stretch / Center setting (Tile and Span are treated as Fill)
WallpaperGeometry(idx) {
    none := {path: "", x: 0, y: 0, w: 0, h: 0}
    if !idx
        return none
    m := MonWalls[idx]
    mw := m.r - m.l, mh := m.b - m.t
    if (m.path = "" || !FileExist(m.path))
        return none
    sz := ImageSize(m.path)
    if (sz[1] <= 0 || sz[2] <= 0)
        return none

    switch WallPos {
        case 2:                                     ; Stretch
            w := mw, h := mh
        case 3:                                     ; Fit
            s := Min(mw / sz[1], mh / sz[2])
            w := Round(sz[1] * s), h := Round(sz[2] * s)
        case 0:                                     ; Center (actual size)
            w := sz[1], h := sz[2]
        default:                                    ; Fill (and Tile/Span)
            s := Max(mw / sz[1], mh / sz[2])
            w := Round(sz[1] * s), h := Round(sz[2] * s)
    }
    return {path: m.path, x: m.l + (mw - w) // 2, y: m.t + (mh - h) // 2, w: w, h: h}
}

;;;;;;-------------------------------------------
ImageSize(path) {
    if ImgSizes.Has(path)
        return ImgSizes[path]
    sz := [0, 0]
    try {
        hBmp := LoadPicture(path)
        bm := Buffer(A_PtrSize = 8 ? 32 : 24, 0)      ; BITMAP struct
        DllCall("GetObject", "ptr", hBmp, "int", bm.Size, "ptr", bm)
        sz := [NumGet(bm, 4, "int"), NumGet(bm, 8, "int")]
        DllCall("DeleteObject", "ptr", hBmp)
    }
    ImgSizes[path] := sz
    return sz
}
