// Desktop buddy: a small creature that lives on the desktop.
// - eyes follow the mouse cursor while it moves (then look straight ahead again), it blinks and breathes
// - hover: it perks up; click: it hops and says something; drag: move it (position is remembered)
// - mood follows the system: sweats when the CPU is hot, sad on low battery, sleeps late at night
//   or when the mouse has been still for a long while
// - it only shows on an empty workspace (no windows): about 2.5 s after you get there it pops up
//   out of the ground with a wobble, a hop, sparkles and a "Hi!",
//   then it is lively: tricks every few seconds, longer strolls, and it chats by itself.
//   When a window is open on the workspace it fades out and everything stops (no timers, no drawing)
// - while the screen is locked it is gone (the desktop shows through the lock screen);
//   helpers/lock-notify tells it the moment the lock starts and ends
// - on battery it saves power: no breathing animation, a trick only about once a minute, slower
//   cursor tracking, no lively empty-workspace mode, and it dozes off after 2 minutes
// - every few seconds it does a trick by itself: spin, dance, big jump, stroll, wink, look around
// - colours are taken from the wallpaper scheme (through `shell`) and made more vivid; when the
//   wallpaper changes it notices and celebrates
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: pet

    required property var shell          // the ShellRoot: colours, cpuTemp, cpu, batPct, batStatus, preview

    // ---------- Settings ----------
    readonly property bool enabled: true
    readonly property real size: 1.45               // 1 = original size
    readonly property int trickEverySec: 9          // a trick by itself about this often (plus up to 6 s)
    readonly property int trickEverySecEmpty: 3     // the same on an empty workspace (plus up to 3 s)
    readonly property int sleepAfterIdleMin: 10     // falls asleep after this many minutes without mouse movement
    readonly property bool onlyOnEmptyWorkspace: true   // false = always on the desktop
    readonly property real appearDelaySec: 2.5      // wait this long on an empty workspace before popping up
    readonly property bool stayOnLeftHalf: true     // never cross the middle of the screen
    readonly property bool batteryAware: true       // calm down while running on battery
    readonly property int trickEverySecBattery: 45  // tricks on battery (plus up to 30 s)
    readonly property int sleepAfterIdleMinBattery: 2
    readonly property int nightFrom: 1              // also sleeps between these hours
    readonly property int nightTo: 6

    // ---------- Colours from the wallpaper ----------
    // The scheme's colours are quite muted, so keep the hue and raise the saturation.
    function vivid(c, sat, lightMin, lightMax) {
        if (c.hslSaturation < 0.06) return c;        // grey wallpaper: stay grey
        return Qt.hsla(c.hslHue, Math.max(c.hslSaturation, sat), Math.max(lightMin, Math.min(lightMax, c.hslLightness)), 1);
    }
    property color bodyColor: vivid(shell.primary, 0.62, 0.60, 0.74)
    property color accentColor: vivid(shell.tertiary, 0.70, 0.62, 0.78)
    readonly property color footColor: Qt.darker(bodyColor, 1.4)
    Behavior on bodyColor { ColorAnimation { duration: 900 } }
    Behavior on accentColor { ColorAnimation { duration: 900 } }

    // ---------- State ----------
    property real posLeft: 130
    property real posBottom: 70
    property real cursorX: -1
    property real cursorY: -1
    property real lastMove: Date.now()
    property real awakeUntil: 0
    property real now: Date.now()
    property bool hovered: false
    property bool dragging: false
    property bool blink: false
    property int lineIndex: 0
    property string speech: ""
    // tricks
    property real burst: 0             // 0..1, drives the little symbols that fly out
    property string burstGlyph: "✦"
    property bool lookForce: false     // eyes follow lookO instead of the cursor
    property real lookO: 0
    property int winkEye: -1
    property int lastTrick: -1
    property bool settled: false       // false for the first seconds, so start-up isn't taken for a wallpaper change

    readonly property bool idle: now - lastMove > 8000
    readonly property bool night: { const h = new Date(now).getHours(); return h >= nightFrom || h < nightTo }
    property bool emptyWs: false       // the current workspace has no windows
    // shown = the window exists and things run; fade = what the opacity animates towards
    property bool shown: !onlyOnEmptyWorkspace
    property bool fadeIn: !onlyOnEmptyWorkspace
    property bool locked: false        // the screen is locked (the desktop shows through the lock screen)
    readonly property bool live: enabled && shown && !locked
    property real unlockedAt: 0        // when the screen was last unlocked: the next entrance says welcome back
    function welcomeLine() {
        const h = new Date().getHours();
        const lines = ["Welcome back!", "You're back!", "I kept watch!", "Missed you!", "Unlocked! Hi!",
                       h < 12 ? "Good morning!" : h < 18 ? "Good afternoon!" : "Good evening!"];
        return lines[Math.floor(Math.random() * lines.length)];
    }
    onLockedChanged: {
        if (locked) {
            // gone at once, no exit animation
            appearTimer.stop(); vanishTimer.stop(); enter.stop(); leave.stop();
            speech = "";
            if (onlyOnEmptyWorkspace) { fadeIn = false; shown = false }
        } else {
            lastMove = Date.now(); now = Date.now();
            unlockedAt = Date.now();
            if (!onlyOnEmptyWorkspace) { awakeUntil = Date.now() + 15000; speech = welcomeLine(); hush.restart() }
            else if (emptyWs) appearTimer.restart();
        }
    }
    onEmptyWsChanged: {
        if (!onlyOnEmptyWorkspace) return;
        if (emptyWs) {
            if (!locked) appearTimer.restart();
        } else {
            appearTimer.stop();
            enter.stop();
            leave.restart();
            fadeIn = false;
            vanishTimer.restart();
        }
    }
    Timer {
        id: appearTimer
        interval: pet.appearDelaySec * 1000
        onTriggered: {
            vanishTimer.stop();
            pet.speech = "";
            pet.lastMove = Date.now();
            pet.now = Date.now();
            pet.shown = true;
            pet.fadeIn = true;
            leave.stop();
            enter.restart();
        }
    }
    Timer { id: vanishTimer; interval: 450; onTriggered: if (!pet.fadeIn) pet.shown = false }
    readonly property bool saver: batteryAware && shell.batStatus === "Discharging"
    readonly property bool lively: emptyWs && !saver
    onLivelyChanged: if (lively) { now = Date.now(); trickTimer.interval = 1200; trickTimer.restart() }
    onSaverChanged: {
        trickTimer.interval = (saver ? trickEverySecBattery : trickEverySec) * 1000;
        trickTimer.restart();
        if (!settled) return;
        awakeUntil = Date.now() + 15000;
        now = Date.now();
        speech = saver ? "On battery. I'll keep still." : "Plugged in! Full energy!";
        hush.restart();
        if (!saver) { burstGlyph = "✦"; burstAnim.restart(); spin.restart() }
    }
    readonly property bool asleep: !lively && now > awakeUntil && !hovered && !dragging
                                   && (night || now - lastMove > (saver ? sleepAfterIdleMinBattery : sleepAfterIdleMin) * 60000)
    readonly property bool hot: shell.cpuTemp >= 85
    readonly property bool lowBattery: shell.batPct > 0 && shell.batPct <= 20 && shell.batStatus !== "Charging"
    readonly property string mood: asleep ? "sleep" : speech !== "" ? "talk" : hot ? "hot" : lowBattery ? "sad" : hovered ? "happy" : "normal"

    Timer { interval: 1000; running: pet.live; repeat: true; onTriggered: pet.now = Date.now() }
    Timer { interval: 6000; running: true; onTriggered: pet.settled = true }

    // ---------- Wallpaper changed: celebrate ----------
    Timer {
        id: wallpaperCheer
        interval: 1200
        onTriggered: {
            pet.awakeUntil = Date.now() + 60000;
            pet.now = Date.now();
            pet.speech = "Ooh, new wallpaper!";
            hush.restart();
            pet.burstGlyph = "✦";
            burstAnim.restart();
            spin.restart();
        }
    }
    Connections {
        target: pet.shell
        function onPrimaryChanged() { if (pet.settled) wallpaperCheer.restart() }
    }

    // ---------- Tricks it does by itself ----------
    Timer {
        id: trickTimer
        interval: pet.trickEverySec * 1000
        running: pet.live && !pet.asleep && !pet.dragging
        repeat: true
        onTriggered: {
            interval = pet.saver ? (pet.trickEverySecBattery + Math.random() * 30) * 1000
                     : pet.lively ? (pet.trickEverySecEmpty + Math.random() * 3) * 1000
                                  : (pet.trickEverySec + Math.random() * 6) * 1000;
            if (pet.speech !== "" || enter.running || spin.running || dance.running || bigJump.running || walk.running || hop.running) return;
            let n;
            // on an empty workspace: strolls and chatter come up more often
            const choices = pet.lively ? [0, 1, 2, 3, 3, 4, 5, 6, 6] : [0, 1, 2, 3, 4, 5];
            do { n = choices[Math.floor(Math.random() * choices.length)] } while (n === pet.lastTrick);
            pet.lastTrick = n;
            if (n === 0) spin.restart();
            else if (n === 1) { pet.burstGlyph = "♪"; burstAnim.restart(); dance.restart() }
            else if (n === 2) bigJump.restart();
            else if (n === 3) pet.stroll();
            else if (n === 4) { pet.winkEye = Math.random() < 0.5 ? 0 : 1; pet.burstGlyph = "♥"; burstAnim.restart(); unwink.restart(); hop.restart() }
            else if (n === 5) lookAround.restart();
            else pet.chatter();
        }
    }

    // says something by itself (empty workspace only)
    function chatter() {
        const t = Math.round(shell.cpuTemp);
        const lines = [
            "So much room in here!", "Look at that wallpaper.", "La la la ♪", "Watch this!", "Wheee!",
            "Want to open something?", "I could do this all day.", "Psst. Hi.", "Nothing to do? Same.",
            "Dance break!", "It's quiet... too quiet.", greeting(),
            t > 0 ? "CPU at " + t + " °C. " + (t >= 80 ? "Phew!" : "All good.") : "All good here.",
            shell.batPct > 0 ? "Battery at " + shell.batPct + "%." : "Hello!"
        ];
        pet.speech = lines[Math.floor(Math.random() * lines.length)];
        hush.restart();
        if (Math.random() < 0.5) { pet.burstGlyph = "✦"; burstAnim.restart() }
        hop.restart();
    }
    Timer { id: unwink; interval: 650; onTriggered: pet.winkEye = -1 }
    NumberAnimation { id: burstAnim; target: pet; property: "burst"; from: 0.02; to: 1; duration: 1100; easing.type: Easing.OutCubic; onFinished: pet.burst = 0 }

    SequentialAnimation {
        id: lookAround
        ScriptAction { script: { pet.lookO = 0; pet.lookForce = true } }
        NumberAnimation { target: pet; property: "lookO"; to: -1; duration: 350; easing.type: Easing.InOutQuad }
        PauseAnimation { duration: 450 }
        NumberAnimation { target: pet; property: "lookO"; to: 1; duration: 500; easing.type: Easing.InOutQuad }
        PauseAnimation { duration: 450 }
        NumberAnimation { target: pet; property: "lookO"; to: 0; duration: 300; easing.type: Easing.InOutQuad }
        ScriptAction { script: pet.lookForce = false }
    }

    // a short walk along the desktop
    property real walkTo: 0
    property int walkDir: 1
    property int walkMs: 2400
    function stroll() {
        const maxLeft = pet.maxLeft();
        let dir = Math.random() < 0.5 ? -1 : 1;
        const dist = pet.lively ? 260 + Math.random() * 380 : 140 + Math.random() * 160;
        if (posLeft + dir * dist < 20 || posLeft + dir * dist > maxLeft - 20) dir = -dir;
        walkDir = dir;
        walkTo = Math.max(0, Math.min(maxLeft, posLeft + dir * dist));
        walkMs = Math.max(1200, Math.round(Math.abs(walkTo - posLeft) * 9 / 400) * 400);
        walk.restart();
    }

    // ---------- Remembered position ----------
    FileView {
        id: store
        path: Quickshell.env("HOME") + "/.local/state/desk-widgets/pet.json"
        blockLoading: true
        printErrors: false
    }
    Component.onCompleted: {
        try {
            const p = JSON.parse(store.text());
            if (typeof p.left === "number" && typeof p.bottom === "number") { posLeft = p.left; posBottom = p.bottom }
        } catch (e) {}
        posLeft = Math.max(0, Math.min(maxLeft(), posLeft));
    }
    // furthest right it may go (left edge of its window)
    function maxLeft() {
        const sw = Quickshell.screens[0] ? Quickshell.screens[0].width : 1920;
        return (stayOnLeftHalf ? sw / 2 : sw) - 220 * size;
    }
    function savePosition() {
        store.setText(JSON.stringify({ left: Math.round(posLeft), bottom: Math.round(posBottom) }));
    }

    // ---------- Mouse cursor position (from Hyprland) ----------
    Process {
        id: cursorProc
        command: ["hyprctl", "cursorpos"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.match(/(-?\d+)\s*,\s*(-?\d+)/);
                if (!m) return;
                const x = +m[1], y = +m[2];
                if (x !== pet.cursorX || y !== pet.cursorY) {
                    pet.cursorX = x; pet.cursorY = y;
                    pet.lastMove = Date.now();
                    pet.watching = true;
                    lookAway.restart();
                }
            }
        }
    }
    Timer {
        // look often while the mouse is moving, rarely when it is still
        // on battery: look less often, and not at all while asleep (hover or click wakes it)
        interval: pet.saver ? (pet.idle ? 3000 : 500) : (pet.idle ? 1000 : 120)
        running: pet.live && !(pet.saver && pet.asleep); repeat: true
        onTriggered: if (!cursorProc.running) cursorProc.running = true
    }

    // ---------- Is the current workspace empty? (from Hyprland) ----------
    Process {
        id: wsProc
        command: ["hyprctl", "--batch", "-j", "activeworkspace ; locked"]
        stdout: StdioCollector {
            onStreamFinished: {
                const w = text.match(/"windows":\s*(\d+)/);
                if (w) pet.emptyWs = +w[1] === 0;
                const l = text.match(/"locked":\s*(true|false)/);
                if (l) pet.locked = l[1] === "true";
            }
        }
    }
    // ---------- Is the screen locked? (told by Hyprland the moment it happens) ----------
    Process {
        command: [Quickshell.shellPath("helpers/lock-notify")]
        running: pet.enabled
        stdout: SplitParser {
            onRead: line => {
                if (line === "locked") pet.locked = true;
                else if (line === "unlocked") pet.locked = false;
                wsSoon.restart();   // and ask once more, in case a check was already under way
            }
        }
    }
    Timer {
        // Hyprland tells us when something changes (below); this is only a slow safety net
        interval: 6000; running: pet.enabled; repeat: true; triggeredOnStart: true
        onTriggered: if (!wsProc.running) wsProc.running = true
    }
    Timer { id: wsSoon; interval: 150; onTriggered: if (!wsProc.running) wsProc.running = true; else wsSoon.restart() }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const n = event.name;
            if (n === "workspace" || n === "workspacev2" || n === "focusedmon" || n === "focusedmonv2"
                    || n === "openwindow" || n === "closewindow" || n === "movewindow" || n === "movewindowv2")
                wsSoon.restart();
        }
    }

    // eyes follow the cursor only while it moves, then go back to looking straight ahead
    property bool watching: false
    Timer { id: lookAway; interval: 1400; onTriggered: pet.watching = false }

    // ---------- Blinking ----------
    Timer {
        interval: 2200 + Math.random() * 3800
        running: pet.live && !pet.asleep; repeat: true
        onTriggered: { pet.blink = true; unblink.restart(); interval = 2200 + Math.random() * 3800 }
    }
    Timer { id: unblink; interval: 130; onTriggered: pet.blink = false }

    // ---------- Talking ----------
    Timer { id: hush; interval: 3800; onTriggered: pet.speech = "" }

    function greeting() {
        const h = new Date().getHours();
        return h < 5 ? "Still up?" : h < 12 ? "Good morning!" : h < 17 ? "Good afternoon!" : h < 22 ? "Good evening!" : "Getting late...";
    }
    function talk() {
        const wasAsleep = pet.asleep;
        pet.awakeUntil = Date.now() + 90000;
        pet.now = Date.now();
        let line;
        if (wasAsleep) {
            line = "...five more minutes.";
        } else {
            const t = Math.round(shell.cpuTemp);
            const fun = ["Boop!", "Nice wallpaper.", "Time for a short break?", "Drink some water.", "I live here now.", "That tickles!"];
            const lines = [
                greeting(),
                t <= 0 ? "Boop!" : t >= 85 ? "It's " + t + " °C in here!" : t >= 70 ? "CPU at " + t + " °C. Getting warm." : "CPU at " + t + " °C. Cosy.",
                shell.batPct > 0 ? "Battery " + shell.batPct + "%" + (shell.batStatus === "Charging" ? ", charging." : shell.batStatus === "Discharging" ? ", on battery." : ", plugged in.") : "Boop!",
                fun[Math.floor(Math.random() * fun.length)]
            ];
            line = lines[pet.lineIndex % lines.length];
            pet.lineIndex++;
        }
        pet.speech = line;
        hush.restart();
        if (!spin.running && !dance.running && !bigJump.running) hop.restart();
    }

    // ---------- Window ----------
    PanelWindow {
        id: win
        visible: pet.live
        screen: Quickshell.screens[0]

        WlrLayershell.layer: pet.shell.preview ? WlrLayer.Overlay : WlrLayer.Bottom
        WlrLayershell.namespace: "desk-pet"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        mask: Region { item: hitBox }    // only the creature takes clicks, the rest passes through

        anchors { left: true; bottom: true }
        margins { left: pet.posLeft; bottom: pet.posBottom }
        implicitWidth: 220 * pet.size
        implicitHeight: 200 * pet.size

        // where clicks land (window coordinates, so scaled by hand)
        Item {
            id: hitBox
            x: (body.x - 4) * pet.size
            y: (body.y - 12) * pet.size
            width: (body.width + 8) * pet.size
            height: (body.height + 16) * pet.size
        }

        // centre of the face in screen coordinates, for the eyes
        readonly property real faceX: pet.posLeft + (body.x + body.width / 2) * pet.size
        readonly property real faceY: (screen ? screen.height : 1080) - pet.posBottom - height + (body.y + bodyShift.y + 34) * pet.size
        readonly property real dx: pet.cursorX - faceX
        readonly property real dy: pet.cursorY - faceY
        readonly property real dist: Math.max(1, Math.sqrt(dx * dx + dy * dy))
        readonly property real reach: pet.cursorX < 0 ? 0 : Math.min(1, dist / 160)
        readonly property real lookX: pet.lookForce ? pet.lookO : pet.mood === "sad" || !pet.watching ? 0 : dx / dist * reach
        readonly property real lookY: pet.lookForce ? -0.15 : pet.mood === "sad" ? 0.8 : !pet.watching ? 0 : dy / dist * reach

        Item {
        id: stage
        width: 220; height: 200
        scale: pet.size
        transformOrigin: Item.TopLeft
        opacity: pet.fadeIn ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: pet.fadeIn ? 220 : 320; easing.type: Easing.InOutQuad } }

        // ----- speech bubble -----
        Rectangle {
            id: bubble
            anchors.horizontalCenter: body.horizontalCenter
            anchors.bottom: body.top
            anchors.bottomMargin: 16
            width: Math.min(204, bubbleText.implicitWidth + 28)
            height: bubbleText.implicitHeight + 18
            radius: 16
            color: Qt.alpha(pet.shell.surface, 0.88)
            border.width: 1
            border.color: Qt.alpha(pet.shell.fg, 0.14)
            opacity: pet.speech !== "" ? 1 : 0
            scale: pet.speech !== "" ? 1 : 0.7
            transformOrigin: Item.Bottom
            Behavior on opacity { NumberAnimation { duration: 180 } }
            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }

            Text {
                id: bubbleText
                anchors.centerIn: parent
                width: Math.min(implicitWidth, 176)
                text: pet.speech
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                font.family: "Rubik"; font.pixelSize: 13
                color: pet.shell.fg
            }
            Rectangle {   // little tail
                width: 12; height: 12; rotation: 45
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.bottom
                color: parent.color
                z: -1
            }
        }

        // ----- shadow on the "ground" -----
        Rectangle {
            anchors.horizontalCenter: body.horizontalCenter
            y: body.y + body.height - 5
            width: 74 - Math.abs(bodyShift.y) * 0.9
            height: 10
            radius: 5
            color: Qt.alpha("#000000", 0.28)
        }

        // ----- the creature -----
        Item {
            id: body
            width: 100; height: 88
            x: (stage.width - width) / 2
            y: stage.height - height - 12
            transform: [
                Scale { id: bodySquash; origin.x: 50; origin.y: 88 },
                Rotation { id: bodyRot; origin.x: 50; origin.y: 48 },
                Translate { id: bodyShift; y: 0 }
            ]

            Item { id: hit; anchors.fill: parent; anchors.margins: -4 }

            // --- entrance: pops up out of the ground, wobbles, hops, sparkles and says hi ---
            SequentialAnimation {
                id: enter
                ScriptAction { script: { bodySquash.xScale = 0; bodySquash.yScale = 0; bodyRot.angle = 0; bodyShift.y = 0 } }
                PauseAnimation { duration: 120 }
                ParallelAnimation {
                    NumberAnimation { target: bodySquash; property: "yScale"; from: 0; to: 1; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 2.6 }
                    NumberAnimation { target: bodySquash; property: "xScale"; from: 0.35; to: 1; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                }
                ScriptAction {
                    script: {
                        const hi = ["Hi!", "Peekaboo!", "I'm back!", "Hello again!", "Ta-da!", "Miss me?"];
                        const back = Date.now() - pet.unlockedAt < 20000;   // just unlocked
                        pet.unlockedAt = 0;
                        pet.speech = back ? pet.welcomeLine() : hi[Math.floor(Math.random() * hi.length)];
                        hush.restart();
                        pet.burstGlyph = "✦";
                        burstAnim.restart();
                    }
                }
                ParallelAnimation {
                    SequentialAnimation {
                        NumberAnimation { target: bodyShift; property: "y"; to: -30; duration: 180; easing.type: Easing.OutQuad }
                        NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 420; easing.type: Easing.OutBounce }
                    }
                    SequentialAnimation {
                        NumberAnimation { target: bodyRot; property: "angle"; to: -10; duration: 150 }
                        NumberAnimation { target: bodyRot; property: "angle"; to: 10; duration: 200 }
                        NumberAnimation { target: bodyRot; property: "angle"; to: 0; duration: 250; easing.type: Easing.OutBack }
                    }
                }
            }
            // --- exit: ducks back into the ground ---
            ParallelAnimation {
                id: leave
                NumberAnimation { target: bodySquash; property: "yScale"; to: 0; duration: 300; easing.type: Easing.InBack }
                NumberAnimation { target: bodySquash; property: "xScale"; to: 0.5; duration: 300; easing.type: Easing.InQuad }
            }

            // --- tricks ---
            ParallelAnimation {
                id: spin
                SequentialAnimation {
                    NumberAnimation { target: bodyShift; property: "y"; to: -34; duration: 260; easing.type: Easing.OutQuad }
                    NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 440; easing.type: Easing.OutBounce }
                }
                NumberAnimation { target: bodyRot; property: "angle"; from: 0; to: 360; duration: 560; easing.type: Easing.InOutQuad }
            }
            SequentialAnimation {
                id: dance
                loops: 3
                ParallelAnimation {
                    NumberAnimation { target: bodyRot; property: "angle"; to: -14; duration: 170; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: bodyShift; property: "y"; to: -9; duration: 170 }
                }
                ParallelAnimation {
                    NumberAnimation { target: bodyRot; property: "angle"; to: 14; duration: 340; easing.type: Easing.InOutQuad }
                    SequentialAnimation {
                        NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 170 }
                        NumberAnimation { target: bodyShift; property: "y"; to: -9; duration: 170 }
                    }
                }
                ParallelAnimation {
                    NumberAnimation { target: bodyRot; property: "angle"; to: 0; duration: 170; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 170 }
                }
            }
            SequentialAnimation {
                id: bigJump
                ParallelAnimation {     // crouch
                    NumberAnimation { target: bodySquash; property: "yScale"; to: 0.68; duration: 230; easing.type: Easing.OutQuad }
                    NumberAnimation { target: bodySquash; property: "xScale"; to: 1.22; duration: 230; easing.type: Easing.OutQuad }
                }
                ParallelAnimation {     // launch
                    NumberAnimation { target: bodySquash; property: "yScale"; to: 1.18; duration: 120 }
                    NumberAnimation { target: bodySquash; property: "xScale"; to: 0.88; duration: 120 }
                    NumberAnimation { target: bodyShift; property: "y"; to: -74; duration: 330; easing.type: Easing.OutQuad }
                }
                ParallelAnimation {     // fall and land
                    NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 300; easing.type: Easing.InQuad }
                    NumberAnimation { target: bodySquash; property: "yScale"; to: 1; duration: 300 }
                    NumberAnimation { target: bodySquash; property: "xScale"; to: 1; duration: 300 }
                }
                ParallelAnimation {
                    NumberAnimation { target: bodySquash; property: "yScale"; to: 0.8; duration: 90 }
                    NumberAnimation { target: bodySquash; property: "xScale"; to: 1.14; duration: 90 }
                }
                ParallelAnimation {
                    NumberAnimation { target: bodySquash; property: "yScale"; to: 1; duration: 260; easing.type: Easing.OutBack }
                    NumberAnimation { target: bodySquash; property: "xScale"; to: 1; duration: 260; easing.type: Easing.OutBack }
                }
            }
            ParallelAnimation {
                id: walk
                NumberAnimation { target: pet; property: "posLeft"; to: pet.walkTo; duration: pet.walkMs; easing.type: Easing.InOutSine }
                SequentialAnimation {
                    NumberAnimation { target: bodyRot; property: "angle"; to: pet.walkDir * 9; duration: 200 }
                    SequentialAnimation {
                        loops: Math.max(1, Math.round(pet.walkMs / 400) - 1)
                        NumberAnimation { target: bodyShift; property: "y"; to: -10; duration: 200; easing.type: Easing.OutQuad }
                        NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 200; easing.type: Easing.InQuad }
                    }
                    NumberAnimation { target: bodyRot; property: "angle"; to: 0; duration: 200 }
                }
            }

            // little symbols that fly out (sparkles, notes, hearts)
            Repeater {
                model: 7
                Text {
                    required property int index
                    readonly property real angle: Math.PI * (1.08 + index * 0.14)      // a fan above the head
                    readonly property real reachPx: 58 + (index % 3) * 16
                    visible: pet.burst > 0
                    text: pet.burstGlyph
                    font.pixelSize: 15 + (index % 3) * 5
                    color: index % 2 ? pet.accentColor : pet.bodyColor
                    style: Text.Outline; styleColor: Qt.alpha("#000000", 0.35)
                    x: 50 - width / 2 + Math.cos(angle) * reachPx * pet.burst
                    y: 30 + Math.sin(angle) * reachPx * pet.burst
                    opacity: 1 - pet.burst * pet.burst
                    scale: 0.5 + pet.burst * 0.9
                    rotation: pet.burst * (index % 2 ? 140 : -140)
                }
            }

            // hop when clicked
            SequentialAnimation {
                id: hop
                NumberAnimation { target: bodyShift; property: "y"; to: -26; duration: 170; easing.type: Easing.OutQuad }
                NumberAnimation { target: bodyShift; property: "y"; to: 0; duration: 380; easing.type: Easing.OutBounce }
            }
            // a small hop of its own now and then
            Timer {
                interval: 45000; running: pet.live && !pet.asleep && !pet.dragging; repeat: true
                onTriggered: if (Math.random() < 0.6) hop.restart()
            }

            // feet
            Repeater {
                model: 2
                Rectangle {
                    required property int index
                    width: 24; height: 14; radius: 7
                    x: index === 0 ? 20 : 56
                    y: body.height - 12
                    color: pet.footColor
                }
            }

            // ears
            Repeater {
                model: 2
                Rectangle {
                    required property int index
                    width: 22; height: 30; radius: 11
                    x: index === 0 ? 12 : 66
                    y: pet.asleep ? 2 : pet.hovered ? -12 : -8
                    rotation: (index === 0 ? -1 : 1) * (pet.asleep ? 38 : pet.mood === "sad" ? 30 : 14)
                    color: pet.bodyColor
                    Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                    Behavior on rotation { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 10; height: 16; radius: 5
                        color: Qt.alpha(pet.accentColor, 0.8)
                    }
                }
            }

            // torso, with a slow breathing motion
            Rectangle {
                id: torso
                width: 100; height: 80
                y: 4
                radius: 38
                color: pet.bodyColor
                border.width: 1
                border.color: Qt.alpha("#000000", 0.18)
                transformOrigin: Item.Bottom
                SequentialAnimation on scale {
                    running: pet.live && !pet.saver   // a constant animation keeps the screen redrawing
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.035; duration: pet.asleep ? 2200 : 1300; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: pet.asleep ? 2200 : 1300; easing.type: Easing.InOutSine }
                }

                // belly
                Rectangle {
                    width: 56; height: 34; radius: 17
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 44
                    color: Qt.alpha("#ffffff", 0.16)
                }

                // eyes
                Repeater {
                    model: 2
                    Rectangle {
                        id: eye
                        required property int index
                        readonly property bool closed: pet.blink || pet.asleep || pet.winkEye === index
                        width: 22; height: 26; radius: 11
                        x: index === 0 ? 20 : 58
                        y: 18
                        color: "#ffffff"
                        transform: Scale {
                            origin.y: 15
                            yScale: eye.closed ? 0.1 : pet.mood === "happy" || pet.mood === "talk" ? 1.08 : 1
                            Behavior on yScale { NumberAnimation { duration: 90 } }
                        }
                        Rectangle {   // pupil
                            width: 11; height: 11; radius: 5.5
                            visible: !eye.closed
                            x: (parent.width - width) / 2 + win.lookX * 4.5
                            y: (parent.height - height) / 2 + win.lookY * 5.5
                            color: "#16161a"
                            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            Rectangle { width: 4; height: 4; radius: 2; x: 2; y: 1.5; color: "#ffffff" }
                        }
                    }
                }

                // cheeks
                Repeater {
                    model: 2
                    Rectangle {
                        required property int index
                        width: 14; height: 8; radius: 4
                        x: index === 0 ? 10 : 76
                        y: 46
                        color: pet.hot ? "#ff6b5e" : pet.accentColor
                        opacity: pet.hot ? 0.9 : pet.hovered || pet.mood === "talk" || pet.winkEye >= 0 ? 0.9 : 0.45
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                }

                // mouth
                Canvas {
                    id: mouth
                    width: 26; height: 16
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 46
                    property string mood: pet.mood
                    onMoodChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        ctx.lineWidth = 2.4;
                        ctx.lineCap = "round";
                        ctx.strokeStyle = "#16161a";
                        ctx.fillStyle = "#16161a";
                        ctx.beginPath();
                        if (mood === "talk") {                 // open mouth
                            ctx.ellipse(8, 2, 10, 11);
                            ctx.fill();
                        } else if (mood === "happy") {         // big smile
                            ctx.moveTo(3, 3); ctx.quadraticCurveTo(13, 17, 23, 3);
                            ctx.stroke();
                        } else if (mood === "sad") {           // frown
                            ctx.moveTo(5, 11); ctx.quadraticCurveTo(13, 2, 21, 11);
                            ctx.stroke();
                        } else if (mood === "hot") {           // wobbly
                            ctx.moveTo(4, 7); ctx.quadraticCurveTo(8, 2, 13, 7); ctx.quadraticCurveTo(18, 12, 22, 7);
                            ctx.stroke();
                        } else if (mood === "sleep") {         // small "o"
                            ctx.ellipse(10, 4, 6, 6);
                            ctx.stroke();
                        } else {                               // small smile
                            ctx.moveTo(7, 4); ctx.quadraticCurveTo(13, 11, 19, 4);
                            ctx.stroke();
                        }
                    }
                }
            }

            // sweat drop when the CPU is hot
            Rectangle {
                visible: pet.hot && !pet.asleep
                width: 9; height: 13; radius: 4.5
                x: 88
                color: "#8fd3ff"
                SequentialAnimation on y {
                    running: pet.hot && !pet.asleep
                    loops: Animation.Infinite
                    NumberAnimation { from: 14; to: 40; duration: 900; easing.type: Easing.InQuad }
                    PauseAnimation { duration: 500 }
                }
            }

            // z z z while asleep
            Repeater {
                model: 3
                Text {
                    id: zed
                    required property int index
                    visible: pet.asleep
                    text: "z"
                    font.family: "Rubik"; font.weight: Font.Medium
                    font.pixelSize: 13 + index * 4
                    color: pet.shell.fg
                    x: 84 + index * 11
                    y: -index * 11
                    opacity: 0.8
                    SequentialAnimation {
                        running: pet.asleep && !pet.saver
                        loops: Animation.Infinite
                        PauseAnimation { duration: zed.index * 450 }
                        ParallelAnimation {
                            NumberAnimation { target: zed; property: "y"; from: 6 - zed.index * 12; to: -14 - zed.index * 12; duration: 1800 }
                            SequentialAnimation {
                                NumberAnimation { target: zed; property: "opacity"; from: 0; to: 0.9; duration: 500 }
                                NumberAnimation { target: zed; property: "opacity"; to: 0; duration: 1300 }
                            }
                        }
                        PauseAnimation { duration: (2 - zed.index) * 450 }
                    }
                }
            }

            // hover, click and drag
            MouseArea {
                anchors.fill: hit
                hoverEnabled: true
                cursorShape: pet.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                property real pressX: 0
                property real pressY: 0
                property bool moved: false
                onEntered: { pet.hovered = true; pet.awakeUntil = Math.max(pet.awakeUntil, Date.now() + 20000) }
                onExited: pet.hovered = false
                onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; moved = false }
                onPositionChanged: mouse => {
                    if (!pressed) return;
                    const mx = mouse.x - pressX, my = mouse.y - pressY;
                    if (!moved && Math.abs(mx) + Math.abs(my) < 6) return;
                    moved = true;
                    pet.dragging = true;
                    const sw = win.screen ? win.screen.width : 1920, sh = win.screen ? win.screen.height : 1080;
                    walk.stop();
                    pet.posLeft = Math.max(-40, Math.min(pet.stayOnLeftHalf ? pet.maxLeft() : sw - win.width + 40, pet.posLeft + mx * pet.size));
                    pet.posBottom = Math.max(0, Math.min(sh - win.height, pet.posBottom - my * pet.size));
                }
                onReleased: {
                    if (moved) { pet.dragging = false; pet.savePosition() }
                    else pet.talk();
                }
            }
        }
        }   // stage
    }
}
