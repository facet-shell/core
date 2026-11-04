.pragma library

// The drawing engine shared by the screen overlay (Super+P), the picture editor and paint.
// A drawing is a list of shapes, plain data so it can be stored and drawn again:
//   { tool, color, width, points: [{ x, y }], text?, size? }
// tool: pen | mark | line | arrow | rect | ellipse | text; color: a Theme role name
// ("accent"), never a color value, so a drawing follows the theme. Points, width and size
// are in document units: screen pixels on the overlay (global layout or canvas
// coordinates), picture pixels in the editor, so the export draws at full resolution.
// A view maps them to an item: item = (doc - origin) * k.
// No QML in here, so the geometry can be checked in node (drop the .pragma line).

var TOOLS = [
    { id: "pen", glyph: 0xF03EA, name: "pen", key: "p" },
    { id: "mark", glyph: 0xF0652, name: "highlighter", key: "h" },
    { id: "line", glyph: 0xF055E, name: "line · shift: 15° steps", key: "l" },
    { id: "arrow", glyph: 0xF005C, name: "arrow · shift: 15° steps", key: "a" },
    { id: "rect", glyph: 0xF0E5F, name: "rectangle · shift: square", key: "r" },
    { id: "ellipse", glyph: 0xF0EA1, name: "ellipse · shift: circle", key: "e" },
    { id: "text", glyph: 0xF0284, name: "text", key: "t" },
    { id: "erase", glyph: 0xF01FE, name: "eraser", key: "x" }
];

// Nerd Font symbols (Symbols Nerd Font Mono, Material Design range) for the other buttons
var GLYPHS = {
    select: 0xF01BF,
    ruler: 0xF046D,
    through: 0xF0CFE,
    undo: 0xF054C,
    redo: 0xF044E,
    clear: 0xF0C62,
    dockLeft: 0xF10AA,
    dockBottom: 0xF10A9
};

// "bg" too: on white paper the light roles hardly show
var COLORS = ["primary", "accent", "secondary", "ok", "warn", "danger", "text", "bg"];
// Pen widths in screen pixels; a shape stores them in document units
var WIDTHS = [2, 4, 8, 14];

// The highlighter: three times as wide, seen through
var MARK_SCALE = 3;
var MARK_ALPHA = 0.35;
// Arrow head: length per unit of line width, half the opening angle in radians
var HEAD_PER_WIDTH = 4.5;
var HEAD_ANGLE = 0.45;
// Text: font size in screen pixels for a pen width
function textSize(width) {
    return 12 + width * 2;
}
// The UI font is monospaced: a character is about this share of the size wide
var CHAR_WIDTH = 0.6;

function toolOfKey(key) {
    for (var i = 0; i < TOOLS.length; i++) {
        if (TOOLS[i].key === key)
            return TOOLS[i].id;
    }
    return "";
}

function isStroke(tool) {
    return tool === "pen" || tool === "mark";
}

function isTwoPoint(tool) {
    return tool === "line" || tool === "arrow" || tool === "rect" || tool === "ellipse";
}

// ── Geometry ─────────────────────────────────────────────────

function round1(v) {
    return Math.round(v * 10) / 10;
}

// b moved so the line a→b runs at a multiple of 15°, keeping its length (Shift)
function snapAngle(a, b) {
    var step = Math.PI / 12;
    var ang = Math.round(Math.atan2(b.y - a.y, b.x - a.x) / step) * step;
    var len = Math.hypot(b.x - a.x, b.y - a.y);
    return { x: a.x + len * Math.cos(ang), y: a.y + len * Math.sin(ang) };
}

// b moved so the box a→b is a square (Shift on rectangle and ellipse)
function snapSquare(a, b) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var s = Math.max(Math.abs(dx), Math.abs(dy));
    return { x: a.x + (dx < 0 ? -s : s), y: a.y + (dy < 0 ? -s : s) };
}

// The filled head at b of an arrow from a: [tip, left, right]
function arrowHead(a, b, width) {
    var ang = Math.atan2(b.y - a.y, b.x - a.x);
    var len = HEAD_PER_WIDTH * width;
    return [
        { x: b.x, y: b.y },
        { x: b.x - len * Math.cos(ang - HEAD_ANGLE), y: b.y - len * Math.sin(ang - HEAD_ANGLE) },
        { x: b.x - len * Math.cos(ang + HEAD_ANGLE), y: b.y - len * Math.sin(ang + HEAD_ANGLE) }
    ];
}

// The line stops inside the head, so a wide line's round cap does not poke out of the tip
function arrowShaftEnd(a, b, width) {
    var len = Math.hypot(b.x - a.x, b.y - a.y);
    if (len === 0)
        return { x: b.x, y: b.y };
    var back = Math.min(len, HEAD_PER_WIDTH * width * Math.cos(HEAD_ANGLE) * 0.8);
    return { x: b.x - (b.x - a.x) / len * back, y: b.y - (b.y - a.y) / len * back };
}

function distToSegment(p, a, b) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var l2 = dx * dx + dy * dy;
    var t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2));
    return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

function distToPolyline(p, pts) {
    if (pts.length === 1)
        return Math.hypot(p.x - pts[0].x, p.y - pts[0].y);
    var best = Infinity;
    for (var i = 1; i < pts.length; i++)
        best = Math.min(best, distToSegment(p, pts[i - 1], pts[i]));
    return best;
}

// Points on the ellipse in the box a→b, for hit tests
function ellipsePoints(a, b, n) {
    var cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    var rx = Math.abs(b.x - a.x) / 2, ry = Math.abs(b.y - a.y) / 2;
    var out = [];
    for (var i = 0; i <= n; i++) {
        var t = i / n * Math.PI * 2;
        out.push({ x: cx + rx * Math.cos(t), y: cy + ry * Math.sin(t) });
    }
    return out;
}

// A text shape's box: points[0] is the start of its baseline
function textBox(s) {
    var p = s.points[0];
    return { x: p.x, y: p.y - s.size * 0.8, w: Math.max(1, s.text.length) * s.size * CHAR_WIDTH, h: s.size };
}

function inTriangle(p, a, b, c) {
    var d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y);
    var d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y);
    var d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y);
    var neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(neg && pos);
}

// Is p (document units) within r of the shape's line? The eraser takes whole shapes.
function hitShape(s, p, r) {
    var pts = s.points;
    if (!pts || pts.length === 0)
        return false;
    var reach = r + (s.tool === "mark" ? s.width * MARK_SCALE : s.width) / 2;
    if (s.tool === "text") {
        var bx = textBox(s);
        return p.x >= bx.x - r && p.x <= bx.x + bx.w + r && p.y >= bx.y - r && p.y <= bx.y + bx.h + r;
    }
    if (isStroke(s.tool))
        return distToPolyline(p, pts) <= reach;
    var a = pts[0], b = pts[pts.length - 1];
    if (s.tool === "line")
        return distToSegment(p, a, b) <= reach;
    if (s.tool === "arrow") {
        if (distToSegment(p, a, b) <= reach)
            return true;
        var h = arrowHead(a, b, s.width);
        return distToPolyline(p, [h[0], h[1], h[2], h[0]]) <= reach || inTriangle(p, h[0], h[1], h[2]);
    }
    if (s.tool === "rect")
        return distToPolyline(p, [a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }, a]) <= reach;
    if (s.tool === "ellipse")
        return distToPolyline(p, ellipsePoints(a, b, 48)) <= reach;
    return false;
}

// Indices of the shapes the eraser at p takes
function hits(shapes, p, r) {
    var out = [];
    for (var i = 0; i < shapes.length; i++) {
        if (hitShape(shapes[i], p, r))
            out.push(i);
    }
    return out;
}

// ── The ruler ────────────────────────────────────────────────
// { x, y, a, len, h } in document units, a in degrees: a straight edge centred on x, y.
// Its body lies on the side of negative "across"; the edge (across 0) is what the pen follows.

function rulerGeom(r) {
    var a = r.a * Math.PI / 180;
    return { cx: r.x, cy: r.y, len: r.len, h: r.h, a: a, ux: Math.cos(a), uy: Math.sin(a), nx: -Math.sin(a), ny: Math.cos(a) };
}

function rulerLocal(r, p) {
    var g = rulerGeom(r), dx = p.x - g.cx, dy = p.y - g.cy;
    return { along: dx * g.ux + dy * g.uy, across: dx * g.nx + dy * g.ny, g: g };
}

// On the ruler's body: dragging there moves it, the wheel turns it
function onRuler(r, p) {
    var l = rulerLocal(r, p);
    return Math.abs(l.along) <= r.len / 2 && l.across <= 0 && l.across >= -r.h;
}

// Screen pixels at either end of the body that turn the ruler instead of moving it
var RULER_GRIP = 26;

// On one of the grips; u is one screen pixel in document units
function onRulerEnd(r, p, u) {
    return onRuler(r, p) && Math.abs(rulerLocal(r, p).along) >= r.len / 2 - RULER_GRIP * u;
}

// Direction from the ruler's centre to p, in degrees like r.a
function rulerAngleTo(r, p) {
    return Math.atan2(p.y - r.y, p.x - r.x) * 180 / Math.PI;
}

// A pen point near the edge lands on it; u is one screen pixel in document units
function snapToRuler(r, p, u) {
    var l = rulerLocal(r, p);
    if (Math.abs(l.along) <= r.len / 2 + 20 * u && l.across > -6 * u && l.across < 28 * u)
        return { x: l.g.cx + l.along * l.g.ux, y: l.g.cy + l.along * l.g.uy, snapped: true };
    return { x: p.x, y: p.y, snapped: false };
}

// Degrees shown on the ruler, 0-359, counter-clockwise like a protractor
function rulerDegrees(a) {
    return Math.round(((-a % 360) + 360) % 360) % 360;
}

// ── Painting ─────────────────────────────────────────────────
// ctx: a 2D context (QML Canvas or HTML canvas). view: { ox, oy, k }. colorOf(role) gives
// the color. Only calls both kinds of context know (no ellipse(): QML's takes a box).

function setView(ctx, view) {
    ctx.setTransform(view.k, 0, 0, view.k, -view.ox * view.k, -view.oy * view.k);
}

function ellipsePath(ctx, a, b) {
    var cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    var rx = Math.abs(b.x - a.x) / 2, ry = Math.abs(b.y - a.y) / 2;
    var kx = rx * 0.5522847, ky = ry * 0.5522847;
    ctx.moveTo(cx + rx, cy);
    ctx.bezierCurveTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
    ctx.bezierCurveTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
    ctx.bezierCurveTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
    ctx.bezierCurveTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
}

// One shape, in document units (the view transform is already set)
function paintShape(ctx, s, colorOf, family) {
    var pts = s.points;
    if (!pts || pts.length === 0)
        return;
    var c = colorOf(s.color);
    ctx.strokeStyle = c;
    ctx.fillStyle = c;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.lineWidth = s.tool === "mark" ? s.width * MARK_SCALE : s.width;
    ctx.globalAlpha = s.tool === "mark" ? MARK_ALPHA : 1;
    if (s.tool === "text") {
        ctx.font = Math.max(1, Math.round(s.size)) + 'px "' + family + '"';
        ctx.fillText(s.text, pts[0].x, pts[0].y);
    } else if (isStroke(s.tool)) {
        ctx.beginPath();
        ctx.moveTo(pts[0].x, pts[0].y);
        // A click without moving still leaves a dot
        if (pts.length === 1)
            ctx.lineTo(pts[0].x + 0.01, pts[0].y);
        for (var i = 1; i < pts.length; i++)
            ctx.lineTo(pts[i].x, pts[i].y);
        ctx.stroke();
    } else {
        var a = pts[0], b = pts[pts.length - 1];
        ctx.beginPath();
        if (s.tool === "line") {
            ctx.moveTo(a.x, a.y);
            ctx.lineTo(b.x, b.y);
        } else if (s.tool === "arrow") {
            var e = arrowShaftEnd(a, b, s.width);
            ctx.moveTo(a.x, a.y);
            ctx.lineTo(e.x, e.y);
        } else if (s.tool === "rect") {
            ctx.rect(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y));
        } else if (s.tool === "ellipse") {
            ellipsePath(ctx, a, b);
            ctx.closePath();
        }
        ctx.stroke();
        if (s.tool === "arrow") {
            var h = arrowHead(a, b, s.width);
            ctx.beginPath();
            ctx.moveTo(h[0].x, h[0].y);
            ctx.lineTo(h[1].x, h[1].y);
            ctx.lineTo(h[2].x, h[2].y);
            ctx.closePath();
            ctx.fill();
        }
    }
    ctx.globalAlpha = 1;
}

function paintShapes(ctx, shapes, view, colorOf, family) {
    ctx.save();
    setView(ctx, view);
    for (var i = 0; i < shapes.length; i++)
        paintShape(ctx, shapes[i], colorOf, family);
    ctx.restore();
}

// The ruler in the theme's facet look; tick labels stay readable at any zoom (k)
function paintRuler(ctx, r, view, colorOf, family) {
    var g = rulerGeom(r), u = 1 / view.k;
    ctx.save();
    setView(ctx, view);
    ctx.translate(g.cx, g.cy);
    ctx.rotate(g.a);
    ctx.globalAlpha = 0.88;
    ctx.fillStyle = colorOf("surface2");
    ctx.fillRect(-g.len / 2, -g.h, g.len, g.h);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = colorOf("secondary");
    ctx.lineWidth = u;
    ctx.strokeRect(-g.len / 2 + u / 2, -g.h + u / 2, g.len - u, g.h - u);
    ctx.fillStyle = colorOf("textDim");
    ctx.font = Math.max(1, Math.round(10 * u)) + 'px "' + family + '"';
    var step = g.len / 40;
    for (var i = 0; i <= 40; i++) {
        var big = i % 5 === 0, x = -g.len / 2 + i * step, tick = (big ? 12 : 6) * u;
        ctx.fillRect(x, -tick, u, tick);
        if (big && i > 0 && i < 40)
            ctx.fillText(String(i / 5), x + 2 * u, -16 * u);
    }
    ctx.fillStyle = colorOf("muted");
    // Three ridges at each end: the grips that turn it
    for (var side = -1; side <= 1; side += 2) {
        for (var j = 0; j < 3; j++)
            ctx.fillRect(side * (g.len / 2 - (7 + 4 * j) * u), -g.h + 6 * u, u, 10 * u);
    }
    ctx.fillText(rulerDegrees(r.a) + "°", -g.len / 2 + 22 * u, -g.h + 14 * u);
    ctx.restore();
}
