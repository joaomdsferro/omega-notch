import QtQuick

// How a nub moves to say what is going on, by name: the names the engine
// accepts for `nub_working` and `nub_waiting`. It only produces numbers (an
// offset along the edge, a stretch of the length and of the depth, an
// opacity) and the nub applies them, so Settings can play the same motion on
// its previews.
Item {
    id: motion

    property string style: "none"
    property bool active: false
    property real unit: 1                  // px per step, the notch scale

    property real along: 0
    property real lengthScale: 1
    property real depthScale: 1
    property real fade: 1
    // A ripple along the nub's outer side: its height as a share of the
    // depth, and how far it has travelled.
    property real wave: 0
    property real wavePhase: 0

    // Names, labels and hints, in the order Settings offers them.
    readonly property var styles: [
        { value: "none", label: "Still", tip: "Stays still" },
        { value: "shiver", label: "Shiver", tip: "A quick shiver along the edge, then a rest" },
        { value: "breathe", label: "Breathe", tip: "Fades slowly out and back in" },
        { value: "wave", label: "Wave", tip: "A ripple runs along it, over and over" },
        { value: "pulse", label: "Pulse", tip: "Two quick beats, like a heart" },
        { value: "bounce", label: "Bounce", tip: "Pops out of the edge and bounces back" },
        { value: "stretch", label: "Stretch", tip: "Grows along the edge and shrinks back" }
    ]

    readonly property bool shivering: active && style === "shiver"
    readonly property bool breathing: active && style === "breathe"
    readonly property bool waving: active && style === "wave"
    readonly property bool pulsing: active && style === "pulse"
    readonly property bool bouncing: active && style === "bounce"
    readonly property bool stretching: active && style === "stretch"

    // A stopped motion snaps back to rest, so switching never leaves the nub
    // half stretched.
    function rest() {
        along = 0
        lengthScale = 1
        depthScale = 1
        fade = 1
        wave = 0
        wavePhase = 0
    }
    onStyleChanged: rest()
    onActiveChanged: if (!active) rest()

    SequentialAnimation {
        running: motion.shivering
        loops: Animation.Infinite
        NumberAnimation { target: motion; property: "along"; to: 1.6 * motion.unit; duration: 45 }
        NumberAnimation { target: motion; property: "along"; to: -1.6 * motion.unit; duration: 90 }
        NumberAnimation { target: motion; property: "along"; to: 1.2 * motion.unit; duration: 90 }
        NumberAnimation { target: motion; property: "along"; to: -1.2 * motion.unit; duration: 90 }
        NumberAnimation { target: motion; property: "along"; to: 0; duration: 45 }
        PauseAnimation { duration: 1500 }
    }

    SequentialAnimation {
        running: motion.breathing
        loops: Animation.Infinite
        NumberAnimation { target: motion; property: "fade"; to: 0.25; duration: 1100; easing.type: Easing.InOutSine }
        NumberAnimation { target: motion; property: "fade"; to: 1; duration: 1100; easing.type: Easing.InOutSine }
        PauseAnimation { duration: 300 }
    }

    // Stretches out to make room, then the ripple runs for as long as it lasts.
    ParallelAnimation {
        running: motion.waving
        NumberAnimation { target: motion; property: "lengthScale"; to: 1.5; duration: 320; easing.type: Easing.OutCubic }
        NumberAnimation { target: motion; property: "depthScale"; to: 1.25; duration: 320; easing.type: Easing.OutCubic }
        NumberAnimation { target: motion; property: "wave"; to: 0.28; duration: 320; easing.type: Easing.OutCubic }
    }
    NumberAnimation {
        running: motion.waving
        loops: Animation.Infinite
        target: motion
        property: "wavePhase"
        from: 0
        to: 2 * Math.PI
        duration: 900
    }

    SequentialAnimation {
        running: motion.pulsing
        loops: Animation.Infinite
        ParallelAnimation {
            NumberAnimation { target: motion; property: "lengthScale"; to: 1.3; duration: 130; easing.type: Easing.OutQuad }
            NumberAnimation { target: motion; property: "depthScale"; to: 1.5; duration: 130; easing.type: Easing.OutQuad }
        }
        ParallelAnimation {
            NumberAnimation { target: motion; property: "lengthScale"; to: 1; duration: 170; easing.type: Easing.InQuad }
            NumberAnimation { target: motion; property: "depthScale"; to: 1; duration: 170; easing.type: Easing.InQuad }
        }
        PauseAnimation { duration: 90 }
        ParallelAnimation {
            NumberAnimation { target: motion; property: "lengthScale"; to: 1.2; duration: 120; easing.type: Easing.OutQuad }
            NumberAnimation { target: motion; property: "depthScale"; to: 1.35; duration: 120; easing.type: Easing.OutQuad }
        }
        ParallelAnimation {
            NumberAnimation { target: motion; property: "lengthScale"; to: 1; duration: 220; easing.type: Easing.InOutQuad }
            NumberAnimation { target: motion; property: "depthScale"; to: 1; duration: 220; easing.type: Easing.InOutQuad }
        }
        PauseAnimation { duration: 1000 }
    }

    SequentialAnimation {
        running: motion.bouncing
        loops: Animation.Infinite
        NumberAnimation { target: motion; property: "depthScale"; to: 2.2; duration: 170; easing.type: Easing.OutQuad }
        NumberAnimation { target: motion; property: "depthScale"; to: 1; duration: 650; easing.type: Easing.OutBounce }
        PauseAnimation { duration: 1100 }
    }

    SequentialAnimation {
        running: motion.stretching
        loops: Animation.Infinite
        NumberAnimation { target: motion; property: "lengthScale"; to: 1.9; duration: 750; easing.type: Easing.InOutSine }
        NumberAnimation { target: motion; property: "lengthScale"; to: 1; duration: 750; easing.type: Easing.InOutSine }
        PauseAnimation { duration: 400 }
    }
}
