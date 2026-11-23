// Desktop widgets (weather + system on the right, battery + network on the left) styled to match Caelestia. v2
// Colours follow Caelestia's wallpaper scheme (~/.local/state/caelestia/scheme.json).
// Start: qs -c desk-widgets -d   Stop: qs kill -c desk-widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // ---------- Settings ----------
    readonly property string location: ""      // "" = adaptive (GeoClue Wi-Fi, then IP). Or fixed "lat,lon", e.g. "6.93,79.85"
    readonly property real cardOpacity: 0.5
    readonly property int edgeMargin: 30
    readonly property int cardWidth: 360
    readonly property bool preview: Quickshell.env("DESK_WIDGETS_PREVIEW") === "1"

    // ---------- Colours from Caelestia ----------
    property var c: ({})
    function col(name, fallback) { return c[name] ? "#" + c[name] : fallback }
    readonly property color surface: col("surface", "#131317")
    readonly property color fg: col("onSurface", "#e5e1e7")
    readonly property color fgDim: col("onSurfaceVariant", "#c8c5d0")
    readonly property color outline: col("outlineVariant", "#47464f")
    readonly property color primary: col("primary", "#c3c0ff")
    readonly property color primaryContainer: col("primaryContainer", "#41407a")
    readonly property color fgAccent: col("onPrimaryContainer", "#e2dfff")
    readonly property color secondary: col("secondary", "#c6c4dd")
    readonly property color tertiary: col("tertiary", "#e9b9d3")
    readonly property color track: col("surfaceContainerHighest", "#353438")

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/caelestia/scheme.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.c = JSON.parse(text()).colours ?? {} } catch (e) {}
        }
    }

    // ---------- CPU / RAM ----------
    property real cpu: 0
    property real ram: 0
    property real ramUsedGb: 0
    property real ramTotalGb: 0
    property var lastCpu: null
    property var cpuHistory: new Array(48).fill(0)

    FileView { id: statFile; path: "/proc/stat"; blockLoading: true }
    FileView { id: memFile; path: "/proc/meminfo"; blockLoading: true }

    // CPU temperature: the zone number can change between boots, so look it up by name once
    property real cpuTemp: 0          // °C, 0 = unknown
    property string cpuTempPath: ""
    readonly property color tempColor: cpuTemp >= 90 ? col("error", "#ffb4ab") : cpuTemp >= 80 ? tertiary : secondary
    Process {
        running: true
        command: ["sh", "-c", "for z in /sys/class/thermal/thermal_zone*; do [ \"$(cat $z/type)\" = x86_pkg_temp ] && echo $z/temp && break; done"]
        stdout: StdioCollector { onStreamFinished: root.cpuTempPath = text.trim() }
    }
    FileView { id: tempFile; path: root.cpuTempPath; blockLoading: true; printErrors: false }

    Timer {
        interval: 1500; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            if (root.cpuTempPath) {
                tempFile.reload();
                const t = parseInt(tempFile.text());
                if (!isNaN(t)) root.cpuTemp = t / 1000;
            }

            statFile.reload();
            const f = statFile.text().split("\n")[0].trim().split(/\s+/).slice(1).map(Number);
            const idle = f[3] + (f[4] || 0);
            const total = f.reduce((a, b) => a + b, 0);
            if (root.lastCpu) {
                const dt = total - root.lastCpu.total;
                if (dt > 0) root.cpu = Math.max(0, Math.min(1, 1 - (idle - root.lastCpu.idle) / dt));
                const h = root.cpuHistory.slice(-47);
                h.push(root.cpu);
                root.cpuHistory = h;
            }
            root.lastCpu = { idle, total };

            memFile.reload();
            const m = {};
            for (const line of memFile.text().split("\n")) {
                const p = line.split(/:\s+/);
                if (p.length === 2) m[p[0]] = parseInt(p[1]);
            }
            if (m.MemTotal) {
                root.ramTotalGb = m.MemTotal / 1048576;
                root.ramUsedGb = (m.MemTotal - m.MemAvailable) / 1048576;
                root.ram = root.ramUsedGb / root.ramTotalGb;
            }
        }
    }

    // ---------- Disks ----------
    property var disks: []   // [{ name, used, size }]

    Process {
        id: dfProc
        command: ["df", "-B1", "--output=target,used,size", "/", "/data"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.trim().split("\n").slice(1)) {
                    const p = line.trim().split(/\s+/);
                    if (p.length === 3) out.push({ name: p[0] === "/" ? "System" : "Data", used: +p[1], size: +p[2] });
                }
                root.disks = out;
            }
        }
    }
    Timer {
        interval: 60000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: dfProc.running = true
    }

    // ---------- Weather (ip-api + open-meteo, same as Caelestia) ----------
    property string city: ""
    property var weather: null
    property var hours: []    // next 6 hours: [{ label, code, day, temp }]

    function get(url, cb) {
        const x = new XMLHttpRequest();
        x.onreadystatechange = () => {
            if (x.readyState === XMLHttpRequest.DONE && x.status === 200) {
                try { cb(JSON.parse(x.responseText)) } catch (e) {}
            }
        };
        x.open("GET", url);
        x.send();
    }

    function fetchWeather(lat, lon) {
        get(`https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}`
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
            + "&hourly=temperature_2m,weather_code,is_day"
            + "&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=2",
            j => {
                const nowHour = j.current.time.slice(0, 13);
                let start = j.hourly.time.findIndex(t => t.slice(0, 13) === nowHour);
                if (start < 0) start = 0;
                const hs = [];
                for (let i = start + 1; i <= start + 6 && i < j.hourly.time.length; i++) {
                    const hr = parseInt(j.hourly.time[i].slice(11, 13));
                    hs.push({
                        label: (hr % 12 || 12) + (hr < 12 ? "am" : "pm"),
                        code: j.hourly.weather_code[i],
                        day: j.hourly.is_day[i],
                        temp: Math.round(j.hourly.temperature_2m[i])
                    });
                }
                root.hours = hs;
                root.weather = j;
            });
    }

    // Location: manual setting > GeoClue (Wi-Fi based, adaptive) > ip-api (internet guess)
    property real geoAccuracy: 0
    property string geoSource: ""

    function cityFromCoords(lat, lon) {
        const x = new XMLHttpRequest();
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE || x.status !== 200) return;
            try {
                const a = JSON.parse(x.responseText).address ?? {};
                root.city = (a.city || a.town || a.village || a.suburb || a.county || a.state || "")
                    .replace(/\s+(M\.C\.|U\.C\.|P\.S\.)\s*Limit$/i, "").replace(/\s+(Municipal|Urban) Council$/i, "");
            } catch (e) {}
        };
        x.open("GET", `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lon}&format=json&zoom=12&accept-language=en`);
        x.setRequestHeader("User-Agent", "desk-widgets/1.0 (quickshell)");
        x.send();
    }

    function ipFallback() {
        get("http://ip-api.com/json?fields=status,city,lat,lon", j => {
            if (j.status !== "success") return;
            root.city = j.city;
            root.geoSource = "ip";
            fetchWeather(j.lat, j.lon);
        });
    }

    Process {
        id: geoProc
        command: ["/usr/lib/geoclue-2.0/demos/where-am-i", "-t", "15", "-a", "8"]
        stdout: StdioCollector {
            onStreamFinished: {
                // use the last (most accurate) location reported
                const last = re => {
                    let m, v = null;
                    const r = new RegExp(re, "g");
                    while ((m = r.exec(text)) !== null) v = parseFloat(m[1]);
                    return v;
                };
                const la = last("Latitude:\\s+(-?[\\d.]+)");
                const lo = last("Longitude:\\s+(-?[\\d.]+)");
                if (la === null || lo === null) { root.ipFallback(); return; }
                const lat = la.toFixed(4), lon = lo.toFixed(4);
                root.geoAccuracy = last("Accuracy:\\s+([\\d.]+)") ?? 0;
                root.geoSource = "geoclue";
                root.cityFromCoords(lat, lon);
                root.fetchWeather(lat, lon);
            }
        }
        onExited: (code) => { if (code !== 0 && root.geoSource !== "geoclue") root.ipFallback(); }
    }

    function refreshWeather() {
        if (root.location) {
            const p = root.location.split(",");
            root.geoSource = "manual";
            cityFromCoords(p[0].trim(), p[1].trim());
            fetchWeather(p[0].trim(), p[1].trim());
        } else if (!geoProc.running) {
            geoProc.running = true;
        }
    }

    Timer {
        interval: 15 * 60 * 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refreshWeather()
    }
    Timer {   // retry if the network wasn't up yet at login
        interval: 20000; running: root.weather === null; repeat: true
        onTriggered: root.refreshWeather()
    }

    function wmo(code, day) {
        if (code === 0) return [day ? "clear_day" : "bedtime", "Clear"];
        if (code <= 2) return [day ? "partly_cloudy_day" : "partly_cloudy_night", "Partly cloudy"];
        if (code === 3) return ["cloud", "Overcast"];
        if (code <= 48) return ["foggy", "Foggy"];
        if (code <= 57) return ["rainy_light", "Drizzle"];
        if (code <= 67) return ["rainy", "Rain"];
        if (code <= 77) return ["weather_snowy", "Snow"];
        if (code <= 82) return ["rainy_heavy", "Showers"];
        if (code <= 86) return ["weather_snowy", "Snow showers"];
        return ["thunderstorm", "Thunderstorm"];
    }

    function gb(bytes) { return (bytes / 1073741824).toFixed(0) }

    // ---------- Battery ----------
    readonly property string batPath: "/sys/class/power_supply/BAT1/"
    property int batPct: 0
    property string batStatus: ""
    property real batWatts: 0
    property real batHours: -1
    property int batHealth: 0
    property int batLimit: 100

    FileView { id: fCap; path: root.batPath + "capacity"; blockLoading: true }
    FileView { id: fStat; path: root.batPath + "status"; blockLoading: true }
    FileView { id: fEnow; path: root.batPath + "energy_now"; blockLoading: true }
    FileView { id: fEfull; path: root.batPath + "energy_full"; blockLoading: true }
    FileView { id: fEdesign; path: root.batPath + "energy_full_design"; blockLoading: true }
    FileView { id: fPow; path: root.batPath + "power_now"; blockLoading: true }
    FileView { id: fLimit; path: root.batPath + "charge_control_end_threshold"; blockLoading: true; printErrors: false }

    Timer {
        interval: 5000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            for (const f of [fCap, fStat, fEnow, fEfull, fEdesign, fPow, fLimit]) f.reload();
            const n = s => parseFloat(s.text().trim());
            root.batPct = n(fCap) || 0;
            root.batStatus = fStat.text().trim();
            const now = n(fEnow), full = n(fEfull), design = n(fEdesign), pow = n(fPow);
            root.batWatts = pow / 1e6;
            root.batHealth = design > 0 ? Math.round(full / design * 100) : 0;
            root.batLimit = n(fLimit) || 100;
            const target = full * root.batLimit / 100;
            if (pow > 0 && root.batStatus === "Discharging") root.batHours = now / pow;
            else if (pow > 0 && root.batStatus === "Charging") root.batHours = Math.max(0, target - now) / pow;
            else root.batHours = -1;
        }
    }

    function hm(h) {
        if (h < 0) return "";
        const t = Math.round(h * 60);
        return t >= 60 ? Math.floor(t / 60) + "h " + (t % 60) + "m" : t + "m";
    }

    // ---------- Network ----------
    property string netName: ""
    property string netType: ""
    property int wifiSignal: 0
    property real rxRate: 0
    property real txRate: 0
    property var lastNet: null
    property var rxHistory: new Array(40).fill(0)
    property var txHistory: new Array(40).fill(0)

    FileView { id: fNetDev; path: "/proc/net/dev"; blockLoading: true }
    FileView { id: fWireless; path: "/proc/net/wireless"; blockLoading: true }

    Timer {
        interval: 1500; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            fNetDev.reload();
            let rx = 0, tx = 0;
            for (const line of fNetDev.text().split("\n").slice(2)) {
                const p = line.trim().split(/[:\s]+/);
                if (p.length < 10 || p[0] === "lo" || p[0].startsWith("docker") || p[0].startsWith("veth") || p[0].startsWith("virbr")) continue;
                rx += +p[1]; tx += +p[9];
            }
            const t = Date.now();
            if (root.lastNet) {
                const dt = (t - root.lastNet.t) / 1000;
                if (dt > 0) {
                    root.rxRate = Math.max(0, (rx - root.lastNet.rx) / dt);
                    root.txRate = Math.max(0, (tx - root.lastNet.tx) / dt);
                    root.rxHistory = root.rxHistory.slice(-39).concat([root.rxRate]);
                    root.txHistory = root.txHistory.slice(-39).concat([root.txRate]);
                }
            }
            root.lastNet = { rx, tx, t };

            fWireless.reload();
            const w = fWireless.text().split("\n")[2];
            root.wifiSignal = w ? Math.min(100, Math.round(parseFloat(w.trim().split(/\s+/)[2]) / 70 * 100)) : 0;
        }
    }

    Process {
        id: nmProc
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.netName = ""; root.netType = "";
                for (const line of text.trim().split("\n")) {
                    const i = line.lastIndexOf(":");
                    const type = line.slice(i + 1);
                    if (type === "loopback" || type === "bridge" || i < 0) continue;
                    root.netName = line.slice(0, i).replace(/\\:/g, ":");
                    root.netType = type.includes("wireless") ? "wifi" : type.includes("ethernet") ? "ethernet" : type;
                    break;
                }
            }
        }
    }
    Timer {
        interval: 10000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: nmProc.running = true
    }

    function speed(b) {
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s";
        if (b >= 1024) return (b / 1024).toFixed(0) + " KB/s";
        return b.toFixed(0) + " B/s";
    }

    // ---------- Desktop buddy (Pet.qml) ----------
    Pet { shell: root }

    // ---------- Window ----------
    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData
            screen: modelData

            WlrLayershell.layer: root.preview ? WlrLayer.Overlay : WlrLayer.Bottom
            WlrLayershell.namespace: "desk-widgets"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            mask: Region {}          // clicks pass through to the desktop

            anchors { top: true; right: true }
            margins { top: root.edgeMargin; right: root.edgeMargin }
            implicitWidth: root.cardWidth
            implicitHeight: column.implicitHeight

            ColumnLayout {
                id: column
                width: root.cardWidth
                spacing: 14

                // ===== Weather =====
                Card {
                    visible: root.weather !== null
                    Layout.preferredHeight: weatherCol.implicitHeight + 44

                    ColumnLayout {
                        id: weatherCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
                        spacing: 14

                        // Header: city + condition
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "location_on"
                                font.family: "Material Symbols Rounded"; font.pixelSize: 16
                                color: root.primary
                            }
                            Text {
                                text: (root.city || "Weather").toUpperCase()
                                font.family: "Rubik"; font.pixelSize: 12; font.weight: Font.Medium; font.letterSpacing: 2
                                color: root.fgDim
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.weather ? root.wmo(root.weather.current.weather_code, root.weather.current.is_day)[1] : ""
                                font.family: "Rubik"; font.pixelSize: 12; font.letterSpacing: 1
                                color: root.fgDim
                            }
                        }

                        // Big temperature + icon
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                text: root.weather ? Math.round(root.weather.current.temperature_2m) : ""
                                font.family: "Rubik"; font.pixelSize: 84; font.weight: Font.Normal
                                color: root.fg
                                Layout.alignment: Qt.AlignBottom
                            }
                            Text {
                                text: "°C"
                                font.family: "Rubik"; font.pixelSize: 26; font.weight: Font.Normal
                                color: root.primary
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: 14
                            }
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                implicitWidth: 92; implicitHeight: 92; radius: 46
                                color: Qt.alpha(root.primaryContainer, 0.75)
                                Text {
                                    anchors.centerIn: parent
                                    text: root.weather ? root.wmo(root.weather.current.weather_code, root.weather.current.is_day)[0] : ""
                                    font.family: "Material Symbols Rounded"; font.pixelSize: 54
                                    color: root.fgAccent
                                }
                            }
                        }

                        // Today's details
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: -6
                            spacing: 14
                            Stat { icon: "arrow_upward"; label: root.weather ? Math.round(root.weather.daily.temperature_2m_max[0]) + "°" : "" }
                            Stat { icon: "arrow_downward"; label: root.weather ? Math.round(root.weather.daily.temperature_2m_min[0]) + "°" : "" }
                            Stat { icon: "humidity_percentage"; label: root.weather ? root.weather.current.relative_humidity_2m + "%" : "" }
                            Stat { icon: "air"; label: root.weather ? Math.round(root.weather.current.wind_speed_10m) + " km/h" : "" }
                        }

                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(root.fg, 0.08) }

                        // Hourly strip
                        Row {
                            id: hourRow
                            Layout.fillWidth: true
                            Repeater {
                                model: root.hours
                                Column {
                                    required property var modelData
                                    width: hourRow.width / 6
                                    spacing: 4
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.label
                                        font.family: "Rubik"; font.pixelSize: 11
                                        color: root.fgDim
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.wmo(modelData.code, modelData.day)[0]
                                        font.family: "Material Symbols Rounded"; font.pixelSize: 22
                                        color: root.secondary
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.temp + "°"
                                        font.family: "Rubik"; font.pixelSize: 13; font.weight: Font.Medium
                                        color: root.fg
                                    }
                                }
                            }
                        }
                    }
                }

                // ===== System =====
                Card {
                    Layout.preferredHeight: sysCol.implicitHeight + 44

                    ColumnLayout {
                        id: sysCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "monitoring"
                                font.family: "Material Symbols Rounded"; font.pixelSize: 16
                                color: root.primary
                            }
                            Text {
                                text: "SYSTEM"
                                font.family: "Rubik"; font.pixelSize: 12; font.weight: Font.Medium; font.letterSpacing: 2
                                color: root.fgDim
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: Math.round(root.cpu * 100) + "%"
                                font.family: "Rubik"; font.pixelSize: 28; font.weight: Font.Normal
                                color: root.fg
                            }
                        }

                        // CPU graph
                        Canvas {
                            id: graph
                            Layout.fillWidth: true
                            implicitHeight: 54
                            property var data: root.cpuHistory
                            property color line: root.primary
                            onDataChanged: requestPaint()
                            onLineChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.reset();
                                const d = data, n = 48;
                                if (d.length < 2) return;
                                const step = width / (n - 1);
                                const x0 = width - (d.length - 1) * step;
                                const y = v => height - 3 - v * (height - 6);
                                ctx.beginPath();
                                ctx.moveTo(x0, y(d[0]));
                                for (let i = 1; i < d.length; i++) ctx.lineTo(x0 + i * step, y(d[i]));
                                ctx.lineWidth = 2;
                                ctx.lineJoin = "round";
                                ctx.strokeStyle = line;
                                ctx.stroke();
                                ctx.lineTo(width, height);
                                ctx.lineTo(x0, height);
                                ctx.closePath();
                                const g = ctx.createLinearGradient(0, 0, 0, height);
                                g.addColorStop(0, Qt.alpha(line, 0.35));
                                g.addColorStop(1, Qt.alpha(line, 0));
                                ctx.fillStyle = g;
                                ctx.fill();
                            }
                        }

                        Meter { icon: "memory"; label: "CPU"; value: root.cpu; detail: Math.round(root.cpu * 100) + "%"; accent: root.primary }
                        Meter { visible: root.cpuTemp > 0; icon: "device_thermostat"; label: "CPU temp"; value: root.cpuTemp / 100; detail: Math.round(root.cpuTemp) + " °C"; accent: root.tempColor }
                        Meter { icon: "memory_alt"; label: "RAM"; value: root.ram; detail: root.ramUsedGb.toFixed(1) + " / " + root.ramTotalGb.toFixed(0) + " GB"; accent: root.tertiary }
                        Repeater {
                            model: root.disks
                            Meter {
                                required property var modelData
                                icon: modelData.name === "System" ? "hard_drive" : "folder"
                                label: modelData.name
                                value: modelData.used / modelData.size
                                detail: root.gb(modelData.used) + " / " + root.gb(modelData.size) + " GB"
                                accent: root.secondary
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- Left column: battery + network ----------
    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData
            screen: modelData

            WlrLayershell.layer: root.preview ? WlrLayer.Overlay : WlrLayer.Bottom
            WlrLayershell.namespace: "desk-widgets"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Normal   // stay clear of Caelestia's bar
            exclusiveZone: 0
            color: "transparent"
            mask: Region {}

            anchors { top: true; left: true }
            margins { top: root.edgeMargin; left: root.edgeMargin }
            implicitWidth: 320
            implicitHeight: leftCol.implicitHeight

            ColumnLayout {
                id: leftCol
                width: 320
                spacing: 14

                // ===== Battery =====
                Card {
                    id: batCard
                    Layout.preferredHeight: batCol.implicitHeight + 44
                    readonly property bool charging: root.batStatus === "Charging"
                    readonly property color batColor: root.batPct <= 15 && !charging ? root.col("error", "#ffb4ab") : root.primary

                    ColumnLayout {
                        id: batCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
                        spacing: 14

                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "battery_horiz_075"; font.family: "Material Symbols Rounded"; font.pixelSize: 16; color: root.primary }
                            Text { text: "BATTERY"; font.family: "Rubik"; font.pixelSize: 12; font.weight: Font.Medium; font.letterSpacing: 2; color: root.fgDim }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.batStatus === "Not charging" ? "Plugged in" : root.batStatus
                                font.family: "Rubik"; font.pixelSize: 12; font.letterSpacing: 1; color: root.fgDim
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 16

                            // Battery body
                            Item {
                                implicitWidth: 120; implicitHeight: 56
                                Rectangle {
                                    id: body
                                    width: 110; height: 56; radius: 16
                                    color: "transparent"
                                    border.width: 2; border.color: Qt.alpha(root.fg, 0.35)
                                    Rectangle {
                                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 6 }
                                        width: Math.max(radius * 2, (parent.width - 12) * root.batPct / 100)
                                        radius: 10
                                        color: batCard.batColor
                                        Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.batStatus === "Charging"
                                        text: "bolt"
                                        font.family: "Material Symbols Rounded"; font.pixelSize: 30
                                        color: root.fgAccent
                                        style: Text.Outline; styleColor: Qt.alpha(root.surface, 0.4)
                                    }
                                }
                                Rectangle {
                                    anchors { left: body.right; leftMargin: 3; verticalCenter: body.verticalCenter }
                                    width: 6; height: 20; radius: 3
                                    color: Qt.alpha(root.fg, 0.35)
                                }
                            }

                            ColumnLayout {
                                spacing: -2
                                RowLayout {
                                    spacing: 0
                                    Text { text: root.batPct; font.family: "Rubik"; font.pixelSize: 52; color: root.fg }
                                    Text { text: "%"; font.family: "Rubik"; font.pixelSize: 20; color: root.primary; Layout.alignment: Qt.AlignTop; Layout.topMargin: 10 }
                                }
                                Text {
                                    text: root.batHours < 0 ? "" : root.hm(root.batHours) + (root.batStatus === "Charging" ? " to " + root.batLimit + "%" : " left")
                                    font.family: "Rubik"; font.pixelSize: 13; color: root.fgDim
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14
                            Stat { icon: "bolt"; label: root.batWatts.toFixed(1) + " W" }
                            Stat { icon: "favorite"; label: root.batHealth + "% health" }
                            Stat { visible: root.batLimit < 100; icon: "shield"; label: "limit " + root.batLimit + "%" }
                        }
                    }
                }

                // ===== Network =====
                Card {
                    Layout.preferredHeight: netCol.implicitHeight + 44

                    ColumnLayout {
                        id: netCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: root.netType === "ethernet" ? "lan" : root.netName === "" ? "wifi_off"
                                    : root.wifiSignal > 66 ? "network_wifi" : root.wifiSignal > 33 ? "network_wifi_2_bar" : "network_wifi_1_bar"
                                font.family: "Material Symbols Rounded"; font.pixelSize: 16; color: root.primary
                            }
                            Text { text: "NETWORK"; font.family: "Rubik"; font.pixelSize: 12; font.weight: Font.Medium; font.letterSpacing: 2; color: root.fgDim }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.netType === "wifi" ? root.wifiSignal + "%" : ""
                                font.family: "Rubik"; font.pixelSize: 12; font.letterSpacing: 1; color: root.fgDim
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.netName || "Disconnected"
                            elide: Text.ElideRight
                            font.family: "Rubik"; font.pixelSize: 22; font.weight: Font.Medium; color: root.fg
                        }

                        Canvas {
                            id: netGraph
                            Layout.fillWidth: true
                            implicitHeight: 50
                            property var rx: root.rxHistory
                            property var tx: root.txHistory
                            property color c1: root.primary
                            property color c2: root.tertiary
                            onRxChanged: requestPaint()
                            onC1Changed: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.reset();
                                const max = Math.max(32768, ...rx, ...tx) * 1.1;
                                const step = width / (rx.length - 1);
                                const y = v => height - 2 - v / max * (height - 4);
                                const draw = (d, col, fill) => {
                                    ctx.beginPath();
                                    ctx.moveTo(0, y(d[0]));
                                    for (let i = 1; i < d.length; i++) ctx.lineTo(i * step, y(d[i]));
                                    ctx.lineWidth = 2; ctx.lineJoin = "round"; ctx.strokeStyle = col; ctx.stroke();
                                    if (fill) {
                                        ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.closePath();
                                        const g = ctx.createLinearGradient(0, 0, 0, height);
                                        g.addColorStop(0, Qt.alpha(col, 0.3)); g.addColorStop(1, Qt.alpha(col, 0));
                                        ctx.fillStyle = g; ctx.fill();
                                    }
                                };
                                draw(rx, c1, true);
                                draw(tx, c2, false);
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            RowLayout {
                                spacing: 4
                                Text { text: "arrow_downward"; font.family: "Material Symbols Rounded"; font.pixelSize: 16; color: root.primary }
                                Text { text: root.speed(root.rxRate); font.family: "Rubik"; font.pixelSize: 14; font.weight: Font.Medium; color: root.fg }
                            }
                            Item { Layout.fillWidth: true }
                            RowLayout {
                                spacing: 4
                                Text { text: "arrow_upward"; font.family: "Material Symbols Rounded"; font.pixelSize: 16; color: root.tertiary }
                                Text { text: root.speed(root.txRate); font.family: "Rubik"; font.pixelSize: 14; font.weight: Font.Medium; color: root.fg }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- Components ----------
    component Card: Rectangle {
        Layout.fillWidth: true
        radius: 26
        color: Qt.alpha(root.surface, root.cardOpacity)
        border.width: 1
        border.color: Qt.alpha(root.fg, 0.10)
    }

    component Stat: RowLayout {
        property string icon
        property string label
        spacing: 3
        Text { text: parent.icon; font.family: "Material Symbols Rounded"; font.pixelSize: 16; color: root.secondary }
        Text { text: parent.label; font.family: "Rubik"; font.pixelSize: 13; color: root.fgDim }
    }

    component Meter: ColumnLayout {
        id: meter
        property string icon
        property string label
        property real value
        property string detail
        property color accent
        property real shown: value
        Behavior on shown { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
        Layout.fillWidth: true
        spacing: 5

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text { text: meter.icon; font.family: "Material Symbols Rounded"; font.pixelSize: 16; color: meter.accent }
            Text { text: meter.label; font.family: "Rubik"; font.pixelSize: 13; font.weight: Font.Medium; color: root.fg }
            Item { Layout.fillWidth: true }
            Text { text: meter.detail; font.family: "Rubik"; font.pixelSize: 12; color: root.fgDim }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 6; radius: 3
            color: Qt.alpha(root.track, 0.8)
            Rectangle {
                width: Math.max(height, parent.width * Math.min(1, meter.shown))
                height: parent.height; radius: 3
                color: meter.accent
            }
        }
    }
}
