import QtQuick

Rectangle {
    id: picker
    required property var app
    property bool opened: false
    property var zones: []
    property string query: ""
    property string message: ""
    property var request: null
    property int serial: 0
    readonly property var filtered: matchingZones(zones,query,app.settingsDraft ? app.settingsDraft.timezone : "")
    anchors.fill: parent
    z: 45
    visible: opened
    color: "white"
    MouseArea { anchors.fill: parent }
    function matchingZones(input, text, current) {
        var search=String(text).trim().toLowerCase().replace(/_/g," ")
        var result=input.filter(function(zone) { return zone.toLowerCase().replace(/_/g," ").indexOf(search)>=0 })
        if(!search && result.indexOf(current)>=0) {
            result=result.filter(function(zone) {return zone!==current})
            result.unshift(current)
        }
        return result
    }
    function choose(zone) {
        if(zones.indexOf(zone)<0 || !app.settingsDraft) return
        app.changeSetting("timezone",zone)
        opened=false
    }
    function close() {
        opened=false; ++serial; deadline.stop()
        if(request) request.abort()
        request=null
    }
    function show() {
        opened=true; query=""; message=""
        if(zones.length) return
        var current=++serial
        var xhr=new XMLHttpRequest(); request=xhr; deadline.restart()
        xhr.onreadystatechange=function() {
            if(xhr.readyState!==XMLHttpRequest.DONE || current!==serial) return
            deadline.stop(); request=null
            try {
                if(xhr.status!==200) throw "Could not load time zones. Close and try again."
                var result=JSON.parse(xhr.responseText)
                if(!Array.isArray(result.timezones) || !result.timezones.length || result.timezones.some(function(z){return typeof z!=="string"}))
                    throw "Invalid time zone list. Close and try again."
                zones=result.timezones
                message=""
            } catch(error) {message=String(error)}
        }
        xhr.open("GET","http://127.0.0.1:38765/timezones"); xhr.send()
    }
    Timer { id:deadline; interval:8000; onTriggered:{++picker.serial;if(picker.request)picker.request.abort();picker.request=null;picker.message="Loading timed out. Close and try again."} }
    Component.onDestruction: { if(request) request.abort() }
    Item {
        id: header
        width:parent.width; height:picker.app.toolbarHeight
        ToolbarTitle { anchors.centerIn:parent; text:"Time zone" }
        ToolbarButton { anchors.right:parent.right; y:12; icon:"close"; label:"Close time zones"; onTriggered:picker.close() }
        Rectangle { anchors.bottom:parent.bottom; width:parent.width; height:2; color:"black" }
    }
    Text {
        id: hint
        anchors.top:header.bottom; anchors.topMargin:16
        x:18; width:parent.width-36
        font.pixelSize:21; color:"black"; wrapMode:Text.Wrap
        text:"Search by city or region. Apply your choice with Save & sync."
    }
    Rectangle {
        id: search
        anchors.top:hint.bottom; anchors.topMargin:12
        x:18; width:parent.width-36; height:60
        border.color:"black"; border.width:2; color:"white"
        Text {
            x:14; width:parent.width-125; anchors.verticalCenter:parent.verticalCenter
            font.pixelSize:25; color:picker.query ? "black" : "#666666"
            text:picker.query || "Search time zones…"; elide:Text.ElideRight; textFormat:Text.PlainText
        }
        SettingsAction { anchors.right:parent.right; anchors.verticalCenter:parent.verticalCenter; width:110; label:"Clear"; onTriggered:picker.query="" }
    }
    ListView {
        id: list
        anchors.top:search.bottom; anchors.topMargin:12
        anchors.bottom:keyboard.top; anchors.bottomMargin:12
        x:18; width:parent.width-36; clip:true
        boundsBehavior:Flickable.StopAtBounds
        model:picker.filtered
        onModelChanged:positionViewAtBeginning()
        delegate:Rectangle {
            required property string modelData
            width:list.width; height:64
            color:picker.app.settingsDraft && picker.app.settingsDraft.timezone===modelData ? picker.app.todayHighlight : "white"
            Text { x:12; width:parent.width-24; anchors.verticalCenter:parent.verticalCenter; font.pixelSize:24; color:"black"; text:parent.modelData.replace(/_/g," "); textFormat:Text.PlainText; elide:Text.ElideRight }
            Rectangle { anchors.bottom:parent.bottom; width:parent.width; height:1; color:"#bbbbbb" }
            MouseArea { anchors.fill:parent; onClicked:picker.choose(parent.modelData) }
        }
        Text {
            visible:picker.filtered.length===0; width:parent.width
            font.pixelSize:23; color:"black"; wrapMode:Text.Wrap
            text:picker.message || (picker.request ? "Loading…" : "No matching time zones")
        }
    }
    Column {
        id: keyboard
        anchors.bottom:parent.bottom; anchors.bottomMargin:14
        x:18; width:parent.width-36; spacing:6
        Repeater {
            model:["qwertyuiop","asdfghjkl","zxcvbnm"]
            delegate:Row {
                required property string modelData
                property string letters:modelData
                width:keyboard.width; spacing:5
                Repeater {
                    model:parent.letters.split("")
                    delegate:Rectangle {
                        required property string modelData
                        width:(keyboard.width-(parent.letters.length-1)*5)/parent.letters.length
                        height:52; color:"white"; border.color:"black"; border.width:1
                        Text { anchors.centerIn:parent; text:parent.modelData.toUpperCase(); font.pixelSize:23; color:"black" }
                        MouseArea { anchors.fill:parent; onClicked:picker.query+=parent.modelData }
                    }
                }
            }
        }
        Row {
            spacing:8
            SettingsAction { width:(keyboard.width-8)/2; label:"Space"; onTriggered:picker.query+=" " }
            SettingsAction { width:(keyboard.width-8)/2; label:"Delete"; onTriggered:picker.query=picker.query.slice(0,-1) }
        }
    }
}
