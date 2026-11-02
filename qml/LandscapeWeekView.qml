import QtQuick

Item {
    id: page
    required property var app
    readonly property real gutter: 76
    readonly property real columnWidth: Math.max(1,(width-gutter)/7)
    readonly property var geometry: ({start:app.displayPrefs.day_scroll ? 0 : app.displayPrefs.day_start,
        end:app.displayPrefs.day_scroll ? 1440 : app.displayPrefs.day_end,
        scale:app.displayPrefs.day_scroll ? app.hourHeight/60 : Math.max(1,timeline.height-24)/Math.max(1,app.displayPrefs.day_end-app.displayPrefs.day_start),
        scroll:!!app.displayPrefs.day_scroll})
    readonly property var columns: visible ? buildColumns(app.events,geometry) : []
    readonly property int allDayCount: visible ? maximumAllDay(app.events) : 0
    readonly property int allDaySlots: Math.min(3,allDayCount)
    function maximumAllDay(events) {
        var counts=[0,0,0,0,0,0,0]
        events.forEach(function(e){if(e.allDay && e.offset>=0 && e.offset<7)counts[e.offset]++})
        return Math.max.apply(null,counts)
    }
    function buildColumns(events, g) {
        var result=[]
        for(var day=0;day<7;day++) {
            var rows=events.filter(function(e){return e.offset===day})
            result.push({allDay:rows.filter(function(e){return e.allDay}),schedule:app.scheduleEvents(rows,g,44)})
        }
        return result
    }
    function timedHit(data, day, x, minute, width) {
        if(day<0 || day>=data.length || x<0 || x>=width) return null
        var entries=data[day].schedule
        for(var i=entries.length-1;i>=0;i--) {
            var e=entries[i]
            var left=4+e.lane*(width-8)/e.lanes
            var right=left+Math.max(1,(width-8)/e.lanes-3)
            if(x>=left && x<right && minute>=e.viewStart && minute<e.renderEnd) return e.event
        }
        return null
    }
    component WeekGestureArea: MouseArea {
        signal tapped(real x,real y)
        property real startX:0
        property real startY:0
        property bool tapCandidate:false
        property string requestedWeek:""
        property string displayedWeek:""
        acceptedButtons:Qt.LeftButton
        preventStealing:false
        onPressed:function(mouse) {
            startX=mouse.x;startY=mouse.y;tapCandidate=true;preventStealing=false
            requestedWeek=app.isoDate(app.monday(app.selectedDate))
            displayedWeek=app.isoDate(app.monday(app.displayedDate))
        }
        onPositionChanged:function(mouse) {
            if(!pressed)return
            var dx=mouse.x-startX,dy=mouse.y-startY
            if(Math.abs(dx)>12 || Math.abs(dy)>12)tapCandidate=false
            if(Math.abs(dx)>24 && Math.abs(dx)>2*Math.abs(dy))preventStealing=true
        }
        onReleased:function(mouse) {
            var dx=mouse.x-startX,dy=mouse.y-startY
            if(requestedWeek===app.isoDate(app.monday(app.selectedDate)) && Math.abs(dx)>=Math.max(60,page.width*0.1) && Math.abs(dx)>2*Math.abs(dy))
                app.shiftWeek(dx<0 ? 1 : -1)
            else if(tapCandidate && displayedWeek===app.isoDate(app.monday(app.displayedDate)))tapped(mouse.x,mouse.y)
            preventStealing=false;tapCandidate=false
        }
        onCanceled:{preventStealing=false;tapCandidate=false}
    }
    CalendarToolbar { id:heading; app:page.app;view:"week" }
    Item {
        id:dates
        anchors.top:heading.bottom
        width:parent.width;height:68
        Repeater {
            model:7
            delegate:Rectangle {
                required property int index
                readonly property date date:page.app.dayAt(index)
                readonly property bool today:page.app.isoDate(date)===page.app.isoDate(page.app.todayDate)
                x:page.gutter+index*page.columnWidth
                width:page.columnWidth;height:dates.height
                color:today ? page.app.todayHighlight : "#d9d9d9"
                Text {anchors.centerIn:parent;text:page.app.days[parent.index].toUpperCase()+" "+parent.date.getDate();font.pixelSize:25;font.bold:true;color:parent.today ? "white" : "black"}
                Rectangle {anchors.right:parent.right;width:1;height:parent.height;color:"#666666"}
                WeekGestureArea {anchors.fill:parent;onTapped:page.app.openDay(parent.index)}
            }
        }
        Rectangle {anchors.bottom:parent.bottom;width:parent.width;height:1;color:"#333333"}
    }
    Item {
        id:allDay
        anchors.top:dates.bottom
        width:parent.width
        height:page.allDaySlots ? page.allDaySlots*34+12+(page.allDayCount>3 ? 24 : 0) : 0
        clip:true
        Text {visible:parent.height>0;x:4;y:8;font.pixelSize:17;font.bold:true;color:"black";text:"All day"}
        Repeater {
            model:7
            delegate:Item {
                required property int index
                property var entries:page.columns[index] ? page.columns[index].allDay : []
                x:page.gutter+index*page.columnWidth;width:page.columnWidth;height:allDay.height
                Repeater {
                    model:parent.entries.slice(0,3)
                    delegate:Item {
                        required property int index
                        required property var modelData
                        y:6+index*34;x:4;width:parent.width-8;height:30
                        Rectangle {width:5;height:parent.height;color:parent.modelData.color}
                        Text {x:10;width:parent.width-14;anchors.verticalCenter:parent.verticalCenter;text:parent.modelData.title;textFormat:Text.PlainText;font.pixelSize:20;font.bold:true;color:"black";elide:Text.ElideRight}
                    }
                }
                Text {visible:parent.entries.length>3;anchors.right:parent.right;anchors.rightMargin:8;anchors.bottom:parent.bottom;text:"+"+(parent.entries.length-3)+" more";font.pixelSize:17;color:"black"}
                Rectangle {anchors.right:parent.right;width:1;height:parent.height;color:"#bbbbbb"}
            }
        }
        Rectangle {visible:allDay.height>0;anchors.bottom:parent.bottom;width:parent.width;height:2;color:"#333333"}
        WeekGestureArea {
            anchors.fill:parent
            onTapped:function(x,y) {
                var day=Math.floor((x-page.gutter)/page.columnWidth)
                if(day<0 || day>=page.columns.length)return
                var slot=Math.floor((y-6)/34)
                var entries=page.columns[day].allDay
                if(slot>=0 && slot<Math.min(3,entries.length))page.app.openEvent(entries[slot],"")
                else if(entries.length>3)page.app.openDay(day)
            }
        }
    }
    Flickable {
        id:timeline
        anchors.top:allDay.bottom;anchors.bottom:parent.bottom
        width:parent.width;clip:true
        interactive:page.geometry.scroll
        flickableDirection:Flickable.VerticalFlick
        boundsBehavior:Flickable.StopAtBounds
        contentHeight:page.geometry.scroll ? page.app.hourHeight*24+24 : height
        onInteractiveChanged:contentY=0
        Connections {target:page.app;function onDisplayedDateChanged(){timeline.contentY=0}}
        Item {
            id:content
            width:timeline.width;height:timeline.contentHeight
            Repeater {
                model:Math.floor((page.geometry.end-page.geometry.start)/60)
                delegate:Item {
                    required property int index
                    y:index*60*page.geometry.scale;width:content.width;height:60*page.geometry.scale
                    Text {x:4;y:2;width:page.gutter-8;font.pixelSize:17;font.weight:Font.DemiBold;color:"black";text:page.app.formatTime(page.app.minuteTime(page.geometry.start+parent.index*60));elide:Text.ElideRight}
                    Rectangle {visible:parent.index>0;x:page.gutter;width:parent.width-page.gutter;height:1;color:"#777777"}
                }
            }
            Repeater {
                model:7
                delegate:Item {
                    required property int index
                    property var schedule:page.columns[index] ? page.columns[index].schedule : []
                    x:page.gutter+index*page.columnWidth;width:page.columnWidth;height:content.height
                    Rectangle {anchors.left:parent.left;width:1;height:parent.height;color:"#bbbbbb"}
                    Repeater {
                        model:parent.schedule
                        delegate:Rectangle {
                            required property var modelData
                            x:4+modelData.lane*(parent.width-8)/modelData.lanes
                            y:(modelData.viewStart-page.geometry.start)*page.geometry.scale
                            width:Math.max(1,(parent.width-8)/modelData.lanes-3)
                            height:(modelData.renderEnd-modelData.viewStart)*page.geometry.scale
                            color:"white";border.width:1;border.color:"black";clip:true
                            Rectangle {width:5;height:parent.height;color:parent.modelData.event.color}
                            Text {x:10;y:3;width:parent.width-14;text:parent.modelData.event.time;font.pixelSize:17;font.weight:Font.DemiBold;color:"black";elide:Text.ElideRight;visible:parent.height>=56}
                            Text {x:10;y:parent.height>=56 ? 25 : 3;width:parent.width-14;height:Math.max(0,parent.height-y-3);text:parent.modelData.event.title;textFormat:Text.PlainText;wrapMode:Text.Wrap;font.pixelSize:20;font.bold:true;color:"black";clip:true}
                        }
                    }
                }
            }
            WeekGestureArea {
                anchors.fill:parent
                onTapped:function(x,y) {
                    var day=Math.floor((x-page.gutter)/page.columnWidth)
                    var hit=page.timedHit(page.columns,day,x-page.gutter-day*page.columnWidth,page.geometry.start+y/page.geometry.scale,page.columnWidth)
                    if(hit)page.app.openEvent(hit,"")
                }
            }
        }
    }
}
