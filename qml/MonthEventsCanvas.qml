import QtQuick

// One paint layer replaces all per-event Text/Rectangle delegates in the month grid.
Canvas {
    id: renderer
    required property var app
    required property var layouts
    required property date gridStart
    required property int rowCount
    property real weekWidth: 64
    property var lineCache: ({})
    property int lineCacheCount: 0
    renderStrategy: Canvas.Immediate
    renderTarget: Canvas.Image

    function fitPrefix(ctx, text, limit) {
        var low = 0;
        var high = text.length;
        while (low < high) {
            var mid = Math.ceil((low + high) / 2);
            if (ctx.measureText(text.slice(0, mid)).width <= limit)
                low = mid;
            else
                high = mid - 1;
        }
        // Do not split a UTF-16 surrogate pair when shortening a long word.
        if (low > 0 && low < text.length && text.charCodeAt(low - 1) >= 0xd800 && text.charCodeAt(low - 1) <= 0xdbff)
            --low;
        return low;
    }
    function elideTitle(ctx, text, limit) {
        text = text.replace(/\s+/g, " ").trim();
        if (ctx.measureText(text).width <= limit)
            return text;
        var ellipsis = "…";
        if (ctx.measureText(ellipsis).width > limit)
            return "";
        var length = fitPrefix(ctx, text, limit - ctx.measureText(ellipsis).width);
        return text.slice(0, length).trim() + ellipsis;
    }
    function titleLines(ctx, title, limit, maxLines) {
        var key = ctx.font + "|" + limit + "|" + maxLines + "|" + title;
        if (lineCache[key] !== undefined)
            return lineCache[key];
        var text = title.replace(/\r\n?/g, "\n").replace(/\t/g, " ").trim();
        var lines = [];
        while (text.length && lines.length < maxLines) {
            if (lines.length === maxLines - 1) {
                lines.push(elideTitle(ctx, text, limit));
                break;
            }
            var newline = text.indexOf("\n");
            var paragraph = newline < 0 ? text : text.slice(0, newline);
            var cut = fitPrefix(ctx, paragraph, limit);
            if (cut === paragraph.length) {
                lines.push(paragraph);
                text = text.slice(cut + (newline >= 0 ? 1 : 0)).replace(/^[ \t]+/, "");
            } else {
                var space = paragraph.lastIndexOf(" ", cut);
                if (space > 0)
                    cut = space;
                if (cut <= 0) {
                    lines.push(elideTitle(ctx, text, limit));
                    break;
                }
                lines.push(paragraph.slice(0, cut).trim());
                text = text.slice(cut).replace(/^[ \t]+/, "");
            }
        }
        if (lineCacheCount >= 512) {
            lineCache = {};
            lineCacheCount = 0;
        }
        lineCache[key] = lines;
        ++lineCacheCount;
        return lines;
    }
    function paintEvents(ctx) {
        var started = Date.now();
        var count = 0;
        ctx.reset();
        ctx.clearRect(0, 0, width, height);
        ctx.textBaseline = "top";
        var cellWidth = (width - weekWidth) / 7;
        var rowHeight = height / rowCount;
        var lineHeight = Math.max(24, Math.ceil(app.monthFontMetrics.height));
        var family = app.monthFontMetrics.font.family || "sans-serif";
        var titleFont = '600 20px "' + family.replace(/"/g, "") + '"';
        for (var index = 0; index < rowCount * 7; index++) {
            var day = new Date(gridStart);
            day.setDate(day.getDate() + index);
            var layout = layouts[app.isoDate(day)];
            if (!layout || (!layout.entries.length && !layout.hidden))
                continue;
            var left = weekWidth + (index % 7) * cellWidth;
            var top = Math.floor(index / 7) * rowHeight;
            ctx.save();
            ctx.beginPath();
            ctx.rect(left + 1, top + 72, cellWidth - 2, Math.max(0, rowHeight - 80));
            ctx.clip();
            ctx.font = titleFont;
            ctx.textAlign = "left";
            for (var i = 0; i < layout.entries.length; i++) {
                var entry = layout.entries[i];
                var y = top + 72 + entry.y;
                ctx.fillStyle = entry.color;
                ctx.fillRect(left + 8, y, 5, entry.height);
                ctx.fillStyle = "black";
                var lines = titleLines(ctx, entry.title, Math.max(1, cellWidth - 27), Math.min(2, Math.max(1, Math.round(entry.height / lineHeight))));
                for (var j = 0; j < lines.length; j++)
                    ctx.fillText(lines[j], left + 19, y + j * lineHeight);
                ++count;
            }
            if (layout.hidden) {
                ctx.font = '17px "' + family.replace(/"/g, "") + '"';
                ctx.textAlign = "right";
                ctx.fillStyle = "black";
                ctx.fillText("+" + layout.hidden + " more", left + cellWidth - 8, top + rowHeight - 28);
            }
            ctx.restore();
        }
        var elapsed = Date.now() - started;
        app.monthPerformance = "Month renderer: Canvas · data " + app.monthLoadMs + "ms · layout " + app.monthLayoutMs + "ms · draw " + elapsed + "ms · " + count + " previews";
        console.warn("Calendar month paint: " + count + " previews, " + elapsed + "ms");
    }
    onPaint: {
        if (!app.monthPublishing)
            paintEvents(getContext("2d"));
    }
    onLayoutsChanged: requestPaint()
    onGridStartChanged: requestPaint()
    onRowCountChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onAvailableChanged: if (available)
        requestPaint()
    onVisibleChanged: if (visible)
        requestPaint()
}
