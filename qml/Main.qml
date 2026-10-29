import QtQuick
import net.asivery.AppLoad 1.0

Rectangle {
    id: root
    anchors.fill: parent
    color: "white"
    signal close
    function unloading() { cancelMonthRequest(); navigationRetry.stop(); navigationDeadline.stop(); if(navigationRequest) navigationRequest.abort(); if(changeRequest) changeRequest.abort(); changeDeadline.stop(); cancelDayRequest(); ++settingsSerial; settingsDeadline.stop(); if (settingsRequest) settingsRequest.abort(); ++generation; ++syncSerial; retry.stop(); requestDeadline.stop(); syncPoll.stop(); syncDeadline.stop(); if (activeRequest) activeRequest.abort(); if (syncRequest) syncRequest.abort(); endpoint.terminate() }
    AppLoad { id: endpoint; applicationID: "org.remarkablecalendar.move" }
    property date selectedDate: new Date()
    property date displayedDate: new Date()
    property bool layoutReady: false
    property date todayDate: new Date()
    property var days: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    property var events: []
    property var activeRequest: null
    property int generation: 0
    property int failures: 0
    property bool syncBusy: false
    property string syncMessage: ""
    property var syncRequest: null
    property int syncSerial: 0
    property int syncFailures: 0
    readonly property color todayHighlight: "#74d2e8"
    readonly property int toolbarHeight: 84
    readonly property int hourHeight: 120
    property var displayPrefs: ({time_format:"12h",day_scroll:false,day_start:420,day_end:1260})
    readonly property var dayGeometryState: dayGeometry()
    onDayGeometryStateChanged: {
        if (layoutReady) {
            daySchedule=scheduleEvents(dayDetailEvents)
            if (!displayPrefs.day_scroll) dayList.contentY=0
        }
    }
    property date monthDate: new Date(new Date().getFullYear(), new Date().getMonth(), 1, 12)
    property string primaryView: "week"
    property string detailsLevel: ""
    property string eventReturnScreen: ""
    property var daySchedule: []
    property date requestedDayDate: new Date()
    property var dayRequest: null
    property int daySerial: 0
    property string dayMessage: ""
    property date detailDayDate: new Date()
    property var dayDetailEvents: []
    property var activeDetailEvent: null
    property bool editOpen: false
    onEditOpenChanged: if (!editOpen) hideEditKeyboard()
    property var editDraft: null
    property string editField: ""
    property string editMessage: ""
    property string originalDescription: ""
    property string originalPlainDescription: ""
    property var writeCalendars: []
    property var pendingChanges: []
    property var confirmChange: null
    property var changeRequest: null
    property bool changeBusy: false
    property bool keyboardShift: false
    property bool keyboardSymbols: false
    property bool settingsOpen: false
    property bool settingsLoading: false
    property bool settingsDirty: false
    property bool catalogRequested: false
    property var settingsDraft: null
    property var calendarOptions: []
    property string settingsMessage: ""
    property var settingsRequest: null
    property int settingsSerial: 0
    property string backendStatus: "Loading calendar…"
    function isoDate(d) {
        return d.getFullYear() + "-" + ("0" + (d.getMonth()+1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
    }
    function monday(d) {
        var copy = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 12)
        copy.setDate(copy.getDate() - ((copy.getDay() + 6) % 7))
        return copy
    }
    function dayAtFor(date, offset) { var d = monday(date); d.setDate(d.getDate() + offset); return d }
    function dayAt(offset) { return dayAtFor(displayedDate, offset) }
    function monthGeometry(date) {
        var firstDay = new Date(date.getFullYear(), date.getMonth(), 1, 12)
        var start = monday(firstDay)
        var days = new Date(firstDay.getFullYear(), firstDay.getMonth() + 1, 0).getDate()
        return {firstDay:firstDay,start:start,rows:Math.ceil(((firstDay.getDay()+6)%7+days)/7)}
    }
    function isoWeekNumber(date) {
        var thursday = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()))
        thursday.setUTCDate(thursday.getUTCDate() + 4 - (thursday.getUTCDay() || 7))
        var yearStart = new Date(Date.UTC(thursday.getUTCFullYear(), 0, 1))
        return Math.ceil((((thursday - yearStart) / 86400000) + 1) / 7)
    }
    function openMonth(date) {
        var target = date instanceof Date ? date : (primaryView === "day" ? detailDayDate : (primaryView === "month" ? monthDate : displayedDate))
        cancelDayRequest()
        primaryView = "month"
        detailsLevel = ""
        loadMonth(new Date(target.getFullYear(), target.getMonth(), 1, 12))
    }
    function shiftMonth(n) {
        openMonth(new Date(requestedMonthDate.getFullYear(), requestedMonthDate.getMonth() + n, 1, 12))
    }
    function openDate(date) {
        cancelMonthRequest()
        cancelDayRequest()
        primaryView = "day"
        detailsLevel = ""
        setDay(date, [])
        loadDay(date)
    }
    function arrangeEvents(input) {
        // Publish only the final measured layout; no visible intermediate column changes.
        titleMeasure.width = Math.max(1, (weekView.width - 10 - 86 - 18) / 2 - 15)
        timeMeasure.forceLayout()
        var available = Math.max(0, weekView.height / 7 - 28)
        var result = input.map(function(event) {
            titleMeasure.text = event.title
            titleMeasure.forceLayout()
            return {id:event.id,offset: event.offset, start: event.start, end: event.end, time: event.time, title: event.title,
                color: event.color, details: event.details, allDay: event.allDay, column: 1, layoutY: 0,
                layoutHeight: Math.max(48, timeMeasure.implicitHeight + titleMeasure.implicitHeight)}
        })
        for (var day = 0; day < 7; day++) {
            var entries = result.filter(function(e) { return e.offset === day })
            var leftUsed = 0
            var morningFull = false
            var right = []
            var rightHeight = 0
            for (var i = 0; i < entries.length; i++) {
                var e = entries[i]
                var leftGap = leftUsed ? 12 : 0
                if (e.start < "12:00" && !morningFull && leftUsed + leftGap + e.layoutHeight <= available) {
                    e.column = 0
                    e.layoutY = leftUsed + leftGap
                    leftUsed = e.layoutY + e.layoutHeight
                } else {
                    if (e.start < "12:00") morningFull = true
                    rightHeight += (right.length ? 12 : 0) + e.layoutHeight
                    right.push(e)
                }
            }
            var spill = []
            var spillHeight = 0
            // Move only a chronological prefix, and only until the right column fits
            // or the next complete entry cannot fit in the remaining left space.
            while (rightHeight > available && right.length && right[0].start >= "12:00") {
                var first = right[0]
                var needed = (spill.length ? 12 : 0) + first.layoutHeight
                if (leftUsed + (leftUsed ? 12 : 0) + spillHeight + needed > available) break
                right.shift()
                rightHeight -= first.layoutHeight + (right.length ? 12 : 0)
                first.column = 0
                spill.push(first)
                spillHeight += needed
            }
            // Preserve top-to-bottom order while bottom-aligning the moved group.
            var spillY = available - spillHeight
            for (var j = 0; j < spill.length; j++) {
                spill[j].layoutY = spillY
                spillY += spill[j].layoutHeight + 12
            }
            var rightY = 0
            for (var k = 0; k < right.length; k++) {
                right[k].layoutY = rightY
                rightY += right[k].layoutHeight + 12
            }
        }
        return result
    }
    function uiEvent(e) {
        return {id:e.id,start:e.start,end:e.end,time:e.all_day ? "All day" : formatRange(e.start,e.end),title:e.title,color:e.color,details:e.details,allDay:!!e.all_day}
    }
    function preferredCalendar(last, calendars) {
        if (last === "local" || calendars.some(function(c) { return c.id===last })) return last
        return calendars.length ? calendars[0].id : "local"
    }
    function hideEditKeyboard() {
        if (Qt.inputMethod) Qt.inputMethod.commit()
        if (keyboardInput) keyboardInput.focus=false
        editField=""
        root.forceActiveFocus()
        if (Qt.inputMethod) Qt.inputMethod.hide()
    }
    function beginEdit(event) {
        if (syncBusy || changeBusy) return
        editMessage=""; editField=""; keyboardSymbols=false
        var d=event && event.details ? event.details : null
        var date=primaryView === "month" ? monthDate : (primaryView === "day" ? detailDayDate : (isoDate(monday(displayedDate))===isoDate(monday(todayDate)) ? todayDate : monday(displayedDate)))
        originalDescription=d ? d.description : ""
        originalPlainDescription=plainDescription(originalDescription)
        editDraft={operation:event ? "update" : "create",id:event ? event.id : "",calendar_id:d && !d.local_event ? d.calendar_id : "local",
            title:event ? event.title : "",start_day:d ? d.start_day : isoDate(date),end_day:d ? d.end_day : isoDate(date),
            start_time:d ? d.start_time : "09:00",end_time:d ? d.end_time : "10:00",all_day:event ? event.allDay : false,
            location:d ? d.location : "",description:originalPlainDescription}
        if (editDraft.all_day) {var last=localDate(editDraft.end_day);last.setDate(last.getDate()-1);editDraft.end_day=isoDate(last)}
        editOpen=true
        settingsHttp("GET",null,function(result){
            if (!event) setEditField("id",result.new_event_id)
            writeCalendars=result.calendars.filter(function(c){return c.available && (c.access_role==="owner" || c.access_role==="writer")})
            if (!event) setEditField("calendar_id",preferredCalendar(result.last_calendar_id,writeCalendars))
            if (!writeCalendars.length) editMessage="No writable Google calendars known. Refresh list in Settings, or choose Local events."
        })
    }
    function setEditField(name,value) {
        if (!editDraft) return
        var copy=JSON.parse(JSON.stringify(editDraft));copy[name]=value;editDraft=copy
    }
    function cycleEditCalendar() {
        hideEditKeyboard()
        if (editDraft.operation!=="create") return
        var choices=[{id:"local"}].concat(writeCalendars)
        var index=0;for(var i=0;i<choices.length;i++) if(choices[i].id===editDraft.calendar_id) index=i
        setEditField("calendar_id",choices[(index+1)%choices.length].id)
    }
    function editCalendarName() {
        if (!editDraft || editDraft.calendar_id==="local") return "Local events (tablet only)"
        var found=writeCalendars.filter(function(c){return c.id===editDraft.calendar_id})
        return found.length ? found[0].name : (activeDetailEvent && activeDetailEvent.details ? activeDetailEvent.details.calendar_name : editDraft.calendar_id)
    }
    function saveEdit() {
        hideEditKeyboard()
        var change=JSON.parse(JSON.stringify(editDraft))
        if (change.description===originalPlainDescription) change.description=originalDescription
        if (change.all_day) {var end=localDate(change.end_day);end.setDate(end.getDate()+1);change.end_day=isoDate(end);change.start_time="00:00";change.end_time="00:00"}
        submitChange(change)
    }
    function submitChange(change) {
        if (changeBusy || syncBusy) return
        changeBusy=true; editMessage="Saving on tablet…"
        var xhr=new XMLHttpRequest();changeRequest=xhr;changeDeadline.restart()
        xhr.onreadystatechange=function(){
            if(xhr.readyState!==XMLHttpRequest.DONE || changeRequest!==xhr) return
            changeDeadline.stop();changeRequest=null;changeBusy=false
            try {
                var result=JSON.parse(xhr.responseText)
                if(xhr.status!==200) throw(result.error || "Could not save change")
                confirmChange=null;editOpen=false;editField="";editMessage=""
                root.loadWeek()
                if(root.primaryView === "month") root.loadMonth(root.requestedMonthDate)
                if(change.operation==="discard") {root.fetchSettings();return}
                if(change.operation==="delete") {
                    detailsLevel=""
                    if(primaryView==="day") loadDay(detailDayDate)
                } else if(result.event) {
                    var dateKey=isoDate(detailDayDate)
                    var rows=dayDetailEvents.filter(function(e){return e.id!==result.event.id})
                    var remote=result.event;var last=remote.end_day || remote.day
                    if(dateKey>=remote.day && dateKey<=last && !(dateKey===last && last>remote.day && remote.end==="00:00")) {
                        var entry=uiEvent(remote)
                        entry.start=dateKey>remote.day ? "00:00" : remote.start
                        entry.end=dateKey<last ? "24:00" : remote.end
                        entry.time=entry.allDay ? "All day" : formatRange(entry.start,entry.end)
                        rows.push(entry)
                    }
                    rows.sort(function(a,b){return a.start.localeCompare(b.start) || a.title.localeCompare(b.title)})
                    dayDetailEvents=rows;daySchedule=scheduleEvents(rows)
                    var origin=primaryView==="day" ? "day" : ""
                    openEvent(uiEvent(result.event),origin)
                }
                if(result.queued) requestSync(true)
            }catch(err){editMessage=xhr.status===0 ? "Save status unknown. Reopen the event before retrying." : String(err)}
        }
        xhr.open("POST","http://127.0.0.1:38765/events/change")
        xhr.setRequestHeader("X-RemarkableCalendar-Request","sync");xhr.setRequestHeader("Content-Type","application/json")
        xhr.send(JSON.stringify(change))
    }
    function refreshActiveEvent(confirmed) {
        if(detailsLevel!=="event" || !activeDetailEvent) return
        var id=activeDetailEvent.id
        var xhr=new XMLHttpRequest()
        xhr.onreadystatechange=function(){
            if(xhr.readyState!==XMLHttpRequest.DONE || detailsLevel!=="event" || !activeDetailEvent || activeDetailEvent.id!==id) return
            if(xhr.status===200){try{activeDetailEvent=uiEvent(JSON.parse(xhr.responseText))}catch(err){}}
            else if(xhr.status===404 && confirmed && activeDetailEvent.details){var copy=JSON.parse(JSON.stringify(activeDetailEvent));copy.details.pending=false;copy.details.sync_error="";activeDetailEvent=copy}
        }
        xhr.open("GET","http://127.0.0.1:38765/events/item?id="+encodeURIComponent(id));xhr.send()
    }
    function keyboardType(key) {
        var start=keyboardInput.selectionStart;var end=keyboardInput.selectionEnd
        if(end>start) keyboardInput.remove(start,end)
        keyboardInput.insert(keyboardInput.cursorPosition,keyboardShift ? key.toUpperCase() : key)
        setEditField(editField,keyboardInput.text)
    }
    function minuteTime(minute) { return (Math.floor(minute/60)<10 ? "0" : "")+Math.floor(minute/60)+":"+(minute%60<10 ? "0" : "")+(minute%60) }
    function formatTime(value, prefs) {
        var choice=prefs || displayPrefs
        if (!value || choice.time_format==="24h") return value || ""
        var hour=Number(value.slice(0,2))%24
        return (hour%12 || 12)+":"+value.slice(3,5)+(hour<12 ? " am" : " pm")
    }
    function formatRange(start,end) { return formatTime(start)+"–"+formatTime(end) }
    function dayGeometry() {
        var scroll=!!displayPrefs.day_scroll
        var start=scroll ? 0 : displayPrefs.day_start
        var end=scroll ? 1440 : displayPrefs.day_end
        var scale=scroll ? hourHeight/60 : Math.max(1,(dayList ? dayList.height : 0)-24)/Math.max(1,end-start)
        return {start:start,end:end,scale:scale,scroll:scroll}
    }
    function openToolbarDay() {
        if (primaryView === "day") return
        if (primaryView === "month") {
            var today = new Date(todayDate)
            var currentMonth = monthDate.getFullYear() === today.getFullYear() && monthDate.getMonth() === today.getMonth()
            openDate(currentMonth ? today : new Date(monthDate))
            return
        }
        var start=monday(displayedDate)
        var today=new Date(todayDate)
        var delta=Math.round((monday(today).getTime()-start.getTime())/86400000)
        openDay(delta===0 ? (today.getDay()+6)%7 : 0)
    }
    function scheduleEvents(input) {
        var g=dayGeometry()
        var timed = input.filter(function(e) { return !e.allDay }).map(function(e) {
            var start = Number(e.start.slice(0,2))*60 + Number(e.start.slice(3,5))
            var endText = e.end || e.time.split("–")[1]
            var end = endText ? Number(endText.slice(0,2))*60 + Number(endText.slice(3,5)) : start+60
            var visibleStart=Math.max(start,g.start)
            var renderEnd=Math.max(end,visibleStart+64/g.scale)
            if (!g.scroll) renderEnd=Math.min(g.end,renderEnd)
            return {event:e,startMinute:start,endMinute:end,viewStart:visibleStart,renderEnd:renderEnd,lane:0,lanes:1}
        }).filter(function(e) { return e.endMinute>g.start && e.startMinute<g.end }).sort(function(a,b) { return a.startMinute-b.startMinute || a.endMinute-b.endMinute })
        var group = []
        var laneEnds = []
        var groupEnd = -1
        function finishGroup() {
            for (var j=0;j<group.length;j++) group[j].lanes = laneEnds.length
        }
        for (var i=0;i<timed.length;i++) {
            var e = timed[i]
            if (e.viewStart >= groupEnd) { finishGroup(); group=[]; laneEnds=[]; groupEnd=-1 }
            var lane=0
            while (lane<laneEnds.length && laneEnds[lane]>e.viewStart) lane++
            e.lane=lane
            laneEnds[lane]=e.renderEnd
            group.push(e)
            groupEnd=Math.max(groupEnd,e.renderEnd)
        }
        finishGroup()
        return timed
    }
    function cancelDayRequest() {
        ++daySerial
        dayDeadline.stop()
        if (dayRequest) dayRequest.abort()
        dayRequest=null
        dayMessage=""
    }
    function setDay(date, input) {
        detailDayDate = new Date(date)
        requestedDayDate = new Date(date)
        dayDetailEvents = input
        daySchedule = scheduleEvents(input)
        rememberNavigation()
        var first = daySchedule.length ? Math.min(7,Math.max(0,Math.floor(daySchedule[0].startMinute/60)-1)) : 7
        dayList.contentY = displayPrefs.day_scroll ? Math.min(first*hourHeight,Math.max(0,dayList.contentHeight-dayList.height)) : 0
    }
    function openDay(offset) {
        if (offset < 0 || offset > 6) return
        cancelDayRequest()
        primaryView = "day"
        detailsLevel = ""
        setDay(root.dayAt(offset),events.filter(function(e) { return e.offset === offset }))
    }
    function loadDay(date) {
        cancelDayRequest()
        requestedDayDate = new Date(date)
        var serial=daySerial
        var wanted=new Date(date)
        var xhr=new XMLHttpRequest()
        dayRequest=xhr
        dayDeadline.restart()
        xhr.onreadystatechange=function() {
            if (xhr.readyState!==XMLHttpRequest.DONE || serial!==daySerial) return
            dayDeadline.stop(); dayRequest=null
            try {
                if (xhr.status!==200) throw "Day unavailable · tap a day arrow to retry"
                var result=JSON.parse(xhr.responseText)
                if (result.start!==isoDate(monday(wanted)) || !Array.isArray(result.events)) throw "Unexpected day response"
                if (result.display) displayPrefs=result.display
                var items=result.events.filter(function(e) { return e.day===isoDate(wanted) }).map(function(e) {
                    return {id:e.id,start:e.start,end:e.end,time:e.all_day ? "All day" : formatRange(e.start,e.end),title:e.title,color:e.color,details:e.details,allDay:!!e.all_day}
                })
                setDay(wanted,items)
            } catch(err) { dayMessage=String(err); requestedDayDate=new Date(detailDayDate) }
        }
        xhr.open("GET","http://127.0.0.1:38765/week?date="+isoDate(wanted)); xhr.send()
    }
    function shiftDay(n) {
        var date=new Date(requestedDayDate)
        date.setDate(date.getDate()+n)
        loadDay(date)
    }
    function showWeek(date) {
        cancelMonthRequest()
        var target = date instanceof Date ? new Date(date) : new Date(primaryView === "month" ? monthDate : detailDayDate)
        cancelDayRequest()
        detailsLevel=""
        primaryView="week"
        if (selectedDate.getTime()===target.getTime()) loadWeek()
        else selectedDate=target
    }
    function openEvent(event, origin) {
        eventReturnScreen = typeof origin === "string" ? origin : (primaryView === "day" ? "day" : "")
        cancelDayRequest()
        requestedDayDate=new Date(detailDayDate)
        activeDetailEvent=event
        detailsLevel="event"
        eventDetailsScroll.contentY=0
        if(root.refreshActiveEvent) root.refreshActiveEvent()
    }
    function closeEvent() { detailsLevel="" }
    function openTimelineTap(x,y) {
        var contentWidth=dayList.width-90
        var g=dayGeometry()
        var hit=daySchedule.filter(function(e) {
            var left=84+e.lane*contentWidth/e.lanes
            return x>=left && x<left+contentWidth/e.lanes-4 && y>=(e.viewStart-g.start)*g.scale && y<(e.renderEnd-g.start)*g.scale
        })
        if (hit.length) openEvent(hit[0].event,"day")
    }
    function localDate(value) {
        var parts = value.split("-")
        return new Date(Number(parts[0]),Number(parts[1])-1,Number(parts[2]),12)
    }
    function eventSpan(event) {
        if (!event || !event.details) return event ? event.time : ""
        var d = event.details
        if (!d.start_day || !d.end_day) return event.time
        if (event.allDay) {
            var last = localDate(d.end_day)
            last.setDate(last.getDate()-1)
            return "All day · " + Qt.formatDate(localDate(d.start_day),"MMM d, yyyy")
                + (isoDate(last) === d.start_day ? "" : " – " + Qt.formatDate(last,"MMM d, yyyy"))
        }
        return Qt.formatDate(localDate(d.start_day),"MMM d, yyyy") + " " + formatTime(d.start_time)
            + " – " + (d.end_day === d.start_day ? "" : Qt.formatDate(localDate(d.end_day),"MMM d, yyyy") + " ") + formatTime(d.end_time)
    }
    function plainDescription(value) {
        // Render stored Google HTML as readable plain text, without loading remote content.
        if (!/<\/?(?:a|p|div|br|span|b|strong|em|i|ul|ol|li|blockquote|img|script|style|h[1-6])(?:\s|\/?>)/i.test(value)) return value
        return value.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, "")
            .replace(/<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, "$2 ($1)")
            .replace(/<br\s*\/?>/gi, "\n").replace(/<\/(?:p|div|li|h[1-6])\s*>/gi, "\n")
            .replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
            .replace(/&quot;/g, '\"').replace(/&#39;/g, "'").replace(/&amp;/g, "&").trim()
    }
    function openWeeklyTap(x, y) {
        var offset = Math.floor(y / (weekView.height / 7))
        if (offset < 0 || offset > 6) return
        var items=events.filter(function(e) { return e.offset===offset })
        var columnWidth = (weekView.width - 10 - 86 - 18) / 2
        var column = x >= 86 && x < 86 + columnWidth ? 0 : (x >= 86 + columnWidth + 18 && x < weekView.width-10 ? 1 : -1)
        var localY = y - offset * weekView.height / 7 - 10
        var limit = Math.max(0, weekView.height / 7 - 28)
        var hit = items.filter(function(e) {
            return e.column === column && e.layoutY + e.layoutHeight <= limit && localY >= e.layoutY && localY < e.layoutY + e.layoutHeight
        })
        if (hit.length) openEvent(hit[0],"")
        else openDay(offset)
    }
    function reflowEvents() {
        if (layoutReady && events.length) events = arrangeEvents(events)
    }
    Timer {id:changeDeadline;interval:8000;onTriggered:{var xhr=root.changeRequest;root.changeRequest=null;if(xhr)xhr.abort();root.changeBusy=false;root.editMessage="Save status unknown. Reopen the event before retrying."}}
    Text { id: titleMeasure; visible: false; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: 25; font.weight: Font.DemiBold }
    Text { id: timeMeasure; visible: false; text: "00:00–00:00"; textFormat: Text.PlainText; font.pixelSize: 21; font.weight: Font.DemiBold }
    function shiftWeek(n) { var d = new Date(selectedDate); d.setDate(d.getDate() + n * 7); selectedDate = d }
    function fail(message) {
        root.backendStatus = message + " · use Sync to retry"
        if (++failures < 10) retry.restart()
    }
    function loadWeek() {
        retry.stop()
        var serial = ++generation
        if (activeRequest) activeRequest.abort()
        var xhr = new XMLHttpRequest()
        activeRequest = xhr
        requestDeadline.restart()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || serial !== generation) return
            requestDeadline.stop()
            activeRequest = null
            if (xhr.status === 200) {
                try {
                    var result = JSON.parse(xhr.responseText)
                    if (result.start !== isoDate(monday(selectedDate)) || !Array.isArray(result.events)) throw "unexpected week"
                    if (result.display) displayPrefs=result.display
                    var newEvents = []
                    for (var i = 0; i < result.events.length; i++) {
                        var e = result.events[i]
                        var offset = -1
                        for (var j = 0; j < 7; j++) if (isoDate(dayAtFor(selectedDate, j)) === e.day) offset = j
                        if (offset < 0) throw "event outside requested week"
                        newEvents.push({id:e.id,offset: offset, start: e.start, end: e.end, time: e.all_day ? "All day" : formatRange(e.start,e.end), title: e.title, color: e.color, details: e.details, allDay: !!e.all_day})
                    }
                    failures = 0
                    root.backendStatus = "Offline calendar"
                    var caches = result.google && result.google.calendars
                    if (caches && caches.length) {
                        var outside = false
                        var oldest = caches[0].synced_at
                        for (var k = 0; k < caches.length; k++) {
                            if (isoDate(dayAtFor(selectedDate, 0)) < caches[k].time_min.slice(0, 10) || isoDate(dayAtFor(selectedDate, 6)) >= caches[k].time_max.slice(0, 10)) outside = true
                            if (caches[k].synced_at < oldest) oldest = caches[k].synced_at
                        }
                        root.backendStatus = (outside ? "Some days outside Google cache" : "Google cache · " + caches.length + " calendar(s)") + " · synced " + oldest.slice(0, 16).replace("T", " ") + " UTC"
                    }
                    if(result.google && result.google.pending_count) root.backendStatus += " · "+result.google.pending_count+" pending changes"
                    root.events = arrangeEvents(newEvents)
                    root.displayedDate = new Date(selectedDate)
                    if (root.primaryView === "week") root.rememberNavigation()
                } catch (err) { fail("Invalid backend response: " + err) }
            } else fail("Backend unavailable")
        }
        xhr.open("GET", "http://127.0.0.1:38765/week?date=" + isoDate(selectedDate))
        xhr.send()
    }
    function requestSync(start, discover) {
        syncPoll.stop()
        var serial = ++syncSerial
        if (syncRequest) syncRequest.abort()
        var xhr = new XMLHttpRequest()
        syncRequest = xhr
        syncBusy = true
        if (start) { syncFailures = 0; syncMessage = "Starting sync…" }
        syncDeadline.restart()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || serial !== syncSerial) return
            syncDeadline.stop()
            syncRequest = null
            try {
                var result = JSON.parse(xhr.responseText)
                if (xhr.status !== 200 && xhr.status !== 202) throw (result.error || "Sync request failed")
                if (["idle", "running", "succeeded", "failed"].indexOf(result.state) < 0) throw "Invalid sync response"
                syncFailures = 0
                syncBusy = result.state === "running"
                syncMessage = result.message || ""
                if (syncBusy) {
                    syncMessage = result.kind === "calendars" ? "Refreshing calendar list…" : "Syncing " + Math.min(result.completed + 1, result.total) + "/" + result.total + " · " + syncMessage
                    syncPoll.restart()
                } else if (result.state === "succeeded" || result.state === "failed") {
                    // Refresh even after a partial failure: earlier calendars may have committed.
                    root.loadWeek()
                    if(root.primaryView === "day") root.loadDay(root.detailDayDate)
                    if(root.primaryView === "month") root.loadMonth(root.requestedMonthDate)
                    root.refreshActiveEvent(result.state==="succeeded" && result.kind!=="calendars")
                    if (root.settingsOpen && !root.settingsDirty) root.fetchSettings()
                }
            } catch (err) {
                if (xhr.status === 0 && ++syncFailures < 5) {
                    syncBusy = true
                    syncMessage = "Reconnecting to sync service…"
                    syncPoll.restart()
                } else {
                    syncBusy = false
                    syncMessage = (xhr.status === 0 ? "Cannot reach sync service" : String(err)) + " · tap Sync to retry"
                }
            }
        }
        xhr.open(start ? "POST" : "GET", "http://127.0.0.1:38765" + (discover ? "/google/calendars/refresh" : "/google/sync"))
        if (start) xhr.setRequestHeader("X-RemarkableCalendar-Request", "sync")
        xhr.send()
    }
    function settingsHttp(method, body, done) {
        var serial = ++settingsSerial
        if (settingsRequest) settingsRequest.abort()
        var xhr = new XMLHttpRequest()
        settingsRequest = xhr
        settingsLoading = true
        settingsDeadline.restart()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || serial !== settingsSerial) return
            settingsDeadline.stop()
            settingsRequest = null
            settingsLoading = false
            try {
                var result = JSON.parse(xhr.responseText)
                if (xhr.status !== 200) throw (result.error || "Settings unavailable")
                done(result)
            } catch (err) { settingsMessage = xhr.status === 0 ? "Cannot reach settings. Try again." : String(err) }
        }
        xhr.open(method, "http://127.0.0.1:38765/settings")
        if (method === "POST") {
            xhr.setRequestHeader("X-RemarkableCalendar-Request", "sync")
            xhr.setRequestHeader("Content-Type", "application/json")
        }
        xhr.send(body === null ? "" : JSON.stringify(body))
    }
    function fetchSettings() {
        settingsMessage = "Loading settings…"
        settingsHttp("GET", null, function(result) {
            settingsDraft = result.settings
            displayPrefs = result.settings
            calendarOptions = result.calendars
            pendingChanges = result.pending || []
            settingsDirty = false
            settingsMessage = calendarOptions.length ? "Choose calendars to display and sync." : "Tap Refresh list to find your Google calendars."
            if (!catalogRequested && !root.syncBusy && (!calendarOptions.length || calendarOptions.some(function(c) { return c.name === c.id }))) {
                catalogRequested = true
                root.requestSync(true,true)
            }
        })
    }
    function changeSetting(name, value) {
        var draft = JSON.parse(JSON.stringify(settingsDraft))
        draft[name] = value
        settingsDraft = draft
        settingsDirty = true
    }
    function toggleCalendar(id) {
        calendarOptions = calendarOptions.map(function(c) {
            return {id:c.id,name:c.name,color:c.color,available:c.available,access_role:c.access_role,enabled:c.id === id ? !c.enabled : c.enabled}
        })
        settingsDirty = true
    }
    function saveSettings() {
        var draft = JSON.parse(JSON.stringify(settingsDraft))
        draft.selected_ids = calendarOptions.filter(function(c) { return c.enabled }).map(function(c) { return c.id })
        settingsMessage = "Saving…"
        settingsHttp("POST", draft, function() {
            displayPrefs = draft
            settingsDirty = false
            settingsOpen = false
            root.loadWeek()
            if(root.primaryView === "day") root.loadDay(root.detailDayDate)
            if(root.primaryView === "month") root.loadMonth(root.requestedMonthDate)
            if (draft.selected_ids.length) root.requestSync(true)
        })
    }
    Timer {
        id: settingsDeadline; interval: 8000
        onTriggered: {
            ++root.settingsSerial
            if (root.settingsRequest) root.settingsRequest.abort()
            root.settingsRequest = null; root.settingsLoading = false
            root.settingsMessage = "Settings request timed out. Reopen Settings to retry."
        }
    }
    Timer {
        id: dayDeadline; interval: 4000
        onTriggered: { ++root.daySerial; if(root.dayRequest) root.dayRequest.abort(); root.dayRequest=null; root.requestedDayDate=new Date(root.detailDayDate); root.dayMessage="Day request timed out · tap a day arrow to retry" }
    }
    Timer { id: syncPoll; interval: 1500; onTriggered: root.requestSync(false) }
    Timer {
        id: syncDeadline; interval: 8000
        onTriggered: {
            ++root.syncSerial
            if (root.syncRequest) root.syncRequest.abort()
            root.syncRequest = null
            root.syncBusy = false
            root.syncMessage = "Cannot check sync progress · tap Sync to retry"
        }
    }
    // Keep the today highlight correct if the app stays open across midnight.
    Timer { interval: 60000; running: true; repeat: true; onTriggered: root.todayDate = new Date() }
    Timer { id: retry; interval: 1000; onTriggered: root.loadWeek() }
    Timer {
        id: requestDeadline; interval: 4000
        onTriggered: {
            ++root.generation
            if (root.activeRequest) root.activeRequest.abort()
            root.activeRequest = null
            root.fail("Backend request timed out")
        }
    }
    onSelectedDateChanged: { if (navigationReady) { failures = 0; loadWeek() } }
    Component.onCompleted: { layoutReady = true; restoreNavigation(); requestSync(false) }
    property bool navigationReady: false
    property var navigationRequest: null
    property string navigationPending: ""
    property int navigationFailures: 0
    function rememberNavigation() {
        if (!navigationReady) return
        navigationPending=JSON.stringify({view:primaryView,date:isoDate(primaryView === "month" ? monthDate : (primaryView === "day" ? detailDayDate : monday(displayedDate)))})
        navigationFailures=0
        saveNavigation()
    }
    function saveNavigation() {
        if (!navigationReady || navigationRequest || !navigationPending) return
        var payload=navigationPending
        var xhr=new XMLHttpRequest()
        navigationRequest=xhr; navigationDeadline.restart()
        xhr.onreadystatechange=function() {
            if(xhr.readyState!==XMLHttpRequest.DONE || navigationRequest!==xhr) return
            navigationRequest=null; navigationDeadline.stop()
            if(xhr.status===200) {
                if(navigationPending===payload) navigationPending=""
                if(navigationPending) saveNavigation()
            } else if(++navigationFailures<5) navigationRetry.restart()
        }
        xhr.open("POST","http://127.0.0.1:38765/navigation")
        xhr.setRequestHeader("X-RemarkableCalendar-Request","sync")
        xhr.setRequestHeader("Content-Type","application/json")
        xhr.send(payload)
    }
    function restoreNavigation() {
        if(navigationRequest || navigationReady) return
        var xhr=new XMLHttpRequest()
        navigationRequest=xhr; navigationDeadline.restart()
        xhr.onreadystatechange=function() {
            if(xhr.readyState!==XMLHttpRequest.DONE || navigationRequest!==xhr) return
            navigationRequest=null; navigationDeadline.stop()
            try {
                if(xhr.status!==200) throw "Navigation unavailable"
                var saved=JSON.parse(xhr.responseText).navigation
                if(saved && (["week","day","month"].indexOf(saved.view)<0 || !/^\d{4}-\d{2}-\d{2}$/.test(saved.date))) throw "Invalid navigation"
                if(saved) {
                    primaryView=saved.view
                    selectedDate=localDate(saved.date)
                    displayedDate=new Date(selectedDate)
                    detailDayDate=new Date(selectedDate)
                    requestedDayDate=new Date(selectedDate)
                    monthDate=new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1, 12)
                }
                navigationReady=true; navigationFailures=0
                loadWeek()
                if(primaryView==="day") loadDay(detailDayDate)
                if(primaryView==="month") loadMonth(monthDate)
            } catch(err) {
                root.backendStatus="Cannot restore calendar view · reconnecting"
                navigationRetry.restart()
            }
        }
        xhr.open("GET","http://127.0.0.1:38765/navigation"); xhr.send()
    }
    Timer { id: navigationRetry; interval: 1000; onTriggered: root.navigationReady ? root.saveNavigation() : root.restoreNavigation() }
    Timer {
        id: navigationDeadline; interval: 4000
        onTriggered: {
            var xhr=root.navigationRequest; root.navigationRequest=null
            if(xhr) xhr.abort()
            if(!root.navigationReady || ++root.navigationFailures<5) navigationRetry.restart()
        }
    }
    property date requestedMonthDate: new Date(monthDate)
    property var monthEvents: []
    property string monthMessage: ""
    property var monthRequest: null
    property int monthSerial: 0
    readonly property var monthTitleMeasure: monthPage.titleMeasure
    function cancelMonthRequest() {
        ++monthSerial
        monthDeadline.stop()
        var xhr=monthRequest; monthRequest=null
        if(xhr) xhr.abort()
        monthMessage=""
    }
    function loadMonth(date) {
        cancelMonthRequest()
        var wanted=new Date(date.getFullYear(),date.getMonth(),1,12)
        requestedMonthDate=wanted
        var serial=monthSerial
        var xhr=new XMLHttpRequest(); monthRequest=xhr; monthDeadline.restart()
        xhr.onreadystatechange=function() {
            if(xhr.readyState!==XMLHttpRequest.DONE || serial!==monthSerial) return
            monthDeadline.stop(); monthRequest=null
            try {
                if(xhr.status!==200) throw "Month unavailable · tap Sync to retry"
                var result=JSON.parse(xhr.responseText)
                var geometry=monthGeometry(wanted)
                var end=new Date(geometry.start); end.setDate(end.getDate()+geometry.rows*7)
                if(result.month!==isoDate(wanted) || result.start!==isoDate(geometry.start) || result.end!==isoDate(end) || !Array.isArray(result.events)) throw "Unexpected month response"
                if(result.display) displayPrefs=result.display
                monthDate=wanted
                monthEvents=result.events
                rememberNavigation()
            } catch(err) { monthMessage=String(err); requestedMonthDate=new Date(monthDate) }
        }
        xhr.open("GET","http://127.0.0.1:38765/month?date="+isoDate(wanted)); xhr.send()
    }
    function arrangeMonthEvents(input, width, height) {
        var grouped={}; var result={}
        monthTitleMeasure.width=Math.max(1,width-27)
        input.forEach(function(event) {
            if(!grouped[event.day]) grouped[event.day]=[]
            monthTitleMeasure.text=event.title
            monthTitleMeasure.forceLayout()
            grouped[event.day].push({id:event.id,title:event.title,color:event.color,height:Math.max(24,Math.ceil(monthTitleMeasure.implicitHeight))})
        })
        var available=Math.max(0,height-64-8-8)
        Object.keys(grouped).forEach(function(day) {
            var items=grouped[day]; var total=0
            items.forEach(function(item,index) { total+=item.height+(index ? 6 : 0) })
            var limit=total>available ? Math.max(0,available-24) : available
            var entries=[]; var used=0
            for(var i=0;i<items.length;i++) {
                var gap=entries.length ? 6 : 0
                if(used+gap+items[i].height>limit) break
                items[i].y=used+gap
                entries.push(items[i]); used+=gap+items[i].height
            }
            result[day]={entries:entries,hidden:items.length-entries.length}
        })
        return result
    }
    Timer {
        id: monthDeadline; interval: 8000
        onTriggered: {
            ++root.monthSerial
            var xhr=root.monthRequest; root.monthRequest=null
            if(xhr) xhr.abort()
            root.requestedMonthDate=new Date(root.monthDate)
            root.monthMessage="Month request timed out · tap Sync to retry"
        }
    }
    // Shared state and requests stay here; screen components receive this controller.
    readonly property var weekView: weekPage.calendar
    readonly property var dayList: dayPage.timeline
    readonly property var eventDetailsScroll: detailsPage.eventScroll
    readonly property var keyboardInput: editorPage.keyboardInput

    function closeSettings() {
        ++settingsSerial
        settingsDeadline.stop()
        if (settingsRequest) settingsRequest.abort()
        settingsRequest = null
        settingsLoading = false
        settingsOpen = false
    }

    WeekView { id: weekPage; app: root; anchors.fill: parent; visible: root.primaryView === "week" }
    DayPage { id: dayPage; app: root; anchors.fill: parent; visible: root.primaryView === "day" }
    MonthView { id: monthPage; app: root; anchors.fill: parent; visible: root.primaryView === "month" }
    SettingsView { app: root }
    DetailsView { id: detailsPage; app: root }
    EventEditor { id: editorPage; app: root }
    ChangeConfirmation { app: root }
}
