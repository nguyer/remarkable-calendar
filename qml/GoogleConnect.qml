import QtQuick

Rectangle {
    id: page
    required property var app
    property bool opened: false
    property var status: ({state:"idle",connected:false,message:""})
    property var request: null
    property int serial: 0
    property bool busy: false
    property string errorMessage: ""
    property bool startup: true
    anchors.fill: parent
    z: 50
    visible: opened
    color: "white"
    MouseArea { anchors.fill: parent }
    function shutdown() {
        ++serial
        opened=false
        startupRetry.stop(); connectionPoll.stop(); deadline.stop()
        if(request) request.abort()
        request=null; busy=false
    }
    function show() {
        opened = true
        errorMessage = ""
        call("", false)
    }
    function close() {
        opened = false
        startup = false
        startupRetry.stop()
        if (request) { ++serial; request.abort(); request=null; deadline.stop(); busy=false }
        call("cancel", false)
    }
    function decodeReply(xhr) {
        if (xhr.status === 0)
            throw "Cannot reach the Calendar backend. Reopen Calendar and try again."
        if (xhr.status === 404 || xhr.status === 405)
            throw "The running Calendar backend does not support Google sign-in. Deploy both the backend and UI, then use AppLoad → Reload and reopen Calendar."
        var text = String(xhr.responseText || "").trim()
        if (!text.length)
            throw "Calendar returned an empty sign-in response (HTTP " + xhr.status + "). Reopen Calendar and try again."
        var value
        try { value = JSON.parse(text) }
        catch (ignored) {
            throw "Calendar returned an unreadable sign-in response (HTTP " + xhr.status + "). Deploy both the backend and UI, then reload AppLoad and reopen Calendar."
        }
        if (!value || typeof value !== "object" || Array.isArray(value))
            throw "Calendar returned an invalid sign-in response. Reopen Calendar and try again."
        if (typeof value.error === "string" && value.error.length) throw value.error
        if (xhr.status !== 200)
            throw "Google sign-in request failed (HTTP " + xhr.status + ")."
        if (["idle","connecting","pending","authorizing","confirm","connected","error","expired"].indexOf(value.state) < 0 || typeof value.connected !== "boolean")
            throw "The Calendar backend returned an unexpected sign-in response. Check that the backend and UI are from the same build."
        return value
    }
    function call(action, initial) {
        if (busy) return
        busy = true
        var current = ++serial
        var xhr = new XMLHttpRequest()
        request = xhr
        deadline.restart()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || current !== serial) return
            deadline.stop(); request=null; busy=false
            try {
                var value = decodeReply(xhr)
                if (JSON.stringify(value) !== JSON.stringify(status)) status=value
                errorMessage=""
                if (initial && startup) {
                    startup=false; startupRetry.stop()
                    if (!value.connected) opened=true
                }
                if (action === "accept") {
                    opened=false
                    app.detailsLevel=""
                    ++app.generation
                    if(app.activeRequest) app.activeRequest.abort()
                    app.cancelDayRequest()
                    app.invalidateMonthCache()
                    app.events=[]; app.dayDetailEvents=[]; app.daySchedule=[]; app.monthEvents=[]
                    if(app.primaryView === "week") app.loadWeek()
                    if(app.primaryView === "day") app.loadDay(app.detailDayDate)
                    if(app.primaryView === "month") app.loadMonth(app.requestedMonthDate)
                    app.settingsDirty=false
                    app.settingsOpen=true
                    app.fetchSettings()
                    app.requestSync(true,true)
                }
            } catch (error) {
                if (!initial) errorMessage=String(error)
            }
        }
        xhr.open(action ? "POST" : "GET", "http://127.0.0.1:38765/google/connect")
        xhr.setRequestHeader("X-RemarkableCalendar-Request", "sync")
        if (action) xhr.setRequestHeader("Content-Type", "application/json")
        if (action) xhr.send(JSON.stringify({action:action}))
        else xhr.send()
    }
    Timer {
        id: deadline; interval: 8000
        onTriggered: {
            ++page.serial
            if(page.request) page.request.abort()
            page.request=null; page.busy=false
            if(page.opened) page.errorMessage="Sign-in request timed out. Try again."
        }
    }
    Timer { id: startupRetry; interval: 1500; repeat:true; running:true; onTriggered: page.call("",true) }
    Timer {
        id: connectionPoll
        interval: 1500; repeat:true
        running: page.opened && ["connecting","pending","authorizing"].indexOf(page.status.state)>=0
        onTriggered: page.call("",false)
    }
    Component.onDestruction: { if(request) request.abort() }
    Item {
        id: header
        width: parent.width; height: page.app.toolbarHeight
        ToolbarTitle { anchors.centerIn:parent; text:"Connect Google" }
        ToolbarButton { anchors.right:parent.right; y:12; icon:"close"; label:"Close sign-in"; onTriggered:page.close() }
        Rectangle { anchors.bottom:parent.bottom; width:parent.width; height:2; color:"black" }
    }
    Column {
        anchors.top:header.bottom; anchors.topMargin:28
        anchors.horizontalCenter:parent.horizontalCenter
        width:parent.width-48; spacing:22
        Text {
            width:parent.width; wrapMode:Text.Wrap; font.pixelSize:28; font.bold:true; color:"black"
            horizontalAlignment:Text.AlignHCenter
            text:page.status.state === "confirm" ? "Use this Google account?" : "Your calendar, on your tablet"
        }
        Text {
            width:parent.width; wrapMode:Text.Wrap; font.pixelSize:23; color:"black"; textFormat:Text.PlainText
            horizontalAlignment:Text.AlignHCenter
            text:page.errorMessage || page.status.message || "Connect over Wi-Fi, then scan a QR code with your phone. You can also use Calendar without Google."
        }
        Canvas {
            id: qr
            anchors.horizontalCenter:parent.horizontalCenter
            width:Math.min(420,parent.width); height:width
            visible:!!page.status.qr && page.status.qr.length>0
            property var rows:page.status.qr || []
            onRowsChanged:requestPaint()
            onWidthChanged:requestPaint()
            onPaint: {
                var ctx=getContext("2d");ctx.reset();ctx.fillStyle="white";ctx.fillRect(0,0,width,height)
                if(!rows.length) return
                var size=Math.floor(width/(rows.length+8))
                var origin=Math.floor((width-size*rows.length)/2)
                ctx.fillStyle="black"
                for(var y=0;y<rows.length;y++) for(var x=0;x<rows[y].length;x++)
                    if(rows[y][x]==="1")ctx.fillRect(origin+x*size,origin+y*size,size,size)
            }
        }
        Text {
            visible:!!page.status.user_code
            width:parent.width; horizontalAlignment:Text.AlignHCenter
            font.pixelSize:36; font.bold:true; color:"black"
            text:page.status.user_code || ""
        }
        Text {
            visible:page.status.state==="confirm"
            width:parent.width; wrapMode:Text.Wrap; horizontalAlignment:Text.AlignHCenter
            font.pixelSize:28; font.bold:true; color:"black"; textFormat:Text.PlainText
            text:page.status.email || ""
        }
        Text {
            visible:page.status.state==="confirm" && page.status.connected
            width:parent.width; wrapMode:Text.Wrap; font.pixelSize:21; color:"black"
            text:"This replaces your Google connection. Local events stay on the tablet; choose your Google calendars again afterward."
        }
        SettingsAction {
            anchors.horizontalCenter:parent.horizontalCenter; width:300
            visible:["idle","error","expired","connected"].indexOf(page.status.state)>=0
            enabled:!page.busy && !page.app.syncBusy
            label:page.status.connected ? "Reconnect Google" : "Connect Google"
            onTriggered:page.call("start",false)
        }
        SettingsAction {
            anchors.horizontalCenter:parent.horizontalCenter; width:300
            visible:page.status.state==="confirm"; enabled:!page.busy
            label:"Use this account"; onTriggered:page.call("accept",false)
        }
        SettingsAction {
            anchors.horizontalCenter:parent.horizontalCenter; width:300
            enabled:!page.busy
            label:["idle","error","expired","connected"].indexOf(page.status.state)>=0 ? "Continue to Calendar" : "Cancel"
            onTriggered:page.close()
        }
    }
}
