/**
 * ACCORDION TYPE — generative kinetic typography
 * Processing 4 (Java mode, default renderer) + ControlP5
 *
 * Words are stretched to fill grid slots whose sizes follow a sine wave.
 * Slot sizes in each column (or row) are normalized to the full canvas
 * length, so as one word grows its neighbours shrink, like an accordion.
 *
 * Direction: vertical, horizontal, radial rings, radial spokes.
 * Gradients: letters, grid (rows / columns), background.
 *
 * Keys:  H = hide/show GUI   S = save PNG   R = toggle frame recording
 *
 * Font: DieGrotesk-A-Bold.otf in the data folder (falls back to any
 * other .ttf/.otf there, then Impact / Arial Black).
 */

import controlP5.*;
import java.io.File;
import java.awt.Graphics2D;
import java.awt.Shape;
import java.awt.RenderingHints;
import java.awt.GradientPaint;
import java.awt.LinearGradientPaint;
import java.awt.RadialGradientPaint;
import java.awt.font.FontRenderContext;
import java.awt.font.GlyphVector;
import java.awt.geom.AffineTransform;
import java.awt.geom.Rectangle2D;

// ------------------------------------------------------------ config
final int   PANEL_W     = 220;                  // GUI strip on the right
final int   X0          = 1000 - PANEL_W + 12;  // left edge of controls
final float FONT_SIZE   = 320;                  // size glyph outlines are built at
final float MIN_WEIGHT  = 0.04;                 // keeps slots from vanishing entirely
final float TIME_MAX    = 120;                  // range of the Time slider (seconds)
final int   NWORDS      = 4;
final int   MIN_LETTERS = 3;
final int   MAX_LETTERS = 10;

// ------------------------------------------------------------ state
ControlP5 cp5;
PGraphics canvas;      // final artwork (what gets saved)
PGraphics layer;       // letters only, on transparent (rect modes)
PGraphics polarSrc;    // letters only, unrolled strip (radial modes)
PFont     wordFont;
PFont     uiFont;
String    fontName = "";

String[]      words      = { "SMALL", "MEDIUM", "LARGE", "XLARGE" };
Shape[]       wordShapes = new Shape[NWORDS];
Rectangle2D[] wordBounds = new Rectangle2D[NWORDS];

// palette: 0 = background, 1 = background 2, 2..5 = word colours 1..4
color[]  pal       = { #000000, #1A1A40, #FF0000, #0000FF, #00E5FF, #FFC400 };
String[] palLabels = { "BG", "BG2", "1", "2", "3", "4" };
int      selSwatch = 2;

// radial lookup table
int[]  polarLut;
int    lutW, lutH, lutSrcW, lutSrcH, lutSamples = 1;
float  lutInner = -1;

float   t = 0;
boolean guiVisible = true;
boolean recording  = false;
int     recFrame   = 0;
boolean guiReady   = false;
String  warnMsg    = "";
int     warnUntil  = 0;

// ============================================================ setup / draw

void setup() {
  size(1000, 1000);
  pixelDensity(1);
  frameRate(60);
  wordFont = loadWordFont();
  uiFont   = createFont("SansSerif", 11);
  canvas   = createGraphics(800, 800);
  buildGui();
  for (int i = 0; i < NWORDS; i++) rebuildWord(i);
  guiReady = true;
}

void draw() {
  background(0);
  syncCanvasSize();

  // time: advance in animation mode, follow the slider in static mode
  if (listIndex("inType") == 0) {
    t += 1.0 / 60.0;                         // fixed step -> smooth recordings
    if (t > TIME_MAX) t -= TIME_MAX;
    Controller tm = cp5.getController("tm");
    tm.setBroadcast(false);
    tm.setValue(t);
    tm.setBroadcast(true);
  } else {
    t = val("tm");
  }

  renderArt();

  // show the artwork, centered in the free area, scaled down if needed
  float areaW = guiVisible ? width - PANEL_W : width;
  float s = min(1, min((areaW - 40) / canvas.width, (height - 40) / (float) canvas.height));
  float dw = canvas.width * s, dh = canvas.height * s;
  image(canvas, (areaW - dw) / 2, (height - dh) / 2, dw, dh);

  if (recording) {
    canvas.save(savePath("frames/frame-" + nf(recFrame++, 5) + ".png"));
  }

  if (guiVisible) drawPanel();

  if (recording) {
    noStroke();
    fill(255, 0, 0);
    ellipse(20, 20, 12, 12);
    fill(255);
    textFont(uiFont, 11);
    textAlign(LEFT, CENTER);
    text("REC " + recFrame, 32, 20);
  }
}

void drawPanel() {
  noStroke();
  fill(16);
  rect(width - PANEL_W, 0, PANEL_W, height);

  // outline around the selected colour swatch (ControlP5 draws on top of this)
  Controller sw = cp5.getController("sw" + selSwatch);
  float[] p = sw.getPosition();
  fill(255);
  rect(p[0] - 2, p[1] - 2, sw.getWidth() + 4, sw.getHeight() + 4);

  fill(255);
  textFont(uiFont, 11);
  textAlign(LEFT, BASELINE);
  text("ACCORDION TYPE", X0 - 4, 22);
  fill(110);
  text("H hide  ·  S save  ·  R record", X0 - 4, height - 30);
  text("font: " + fontName, X0 - 4, height - 14);
  if (millis() < warnUntil) {
    fill(255, 80, 80);
    text(warnMsg, X0 - 4, height - 50);
  }
}

// ============================================================ the effect
//
// Every frame:
//   1. letters are drawn (as stretched glyph outlines) onto a transparent layer
//   2. the background (solid or gradient) is drawn into the canvas
//   3. the letter layer is composited over it — 1:1 for vertical/horizontal,
//      or through a polar lookup table for the radial modes.
//      Difference mode is applied here: white letters invert what's beneath.

void renderArt() {
  int     dir  = listIndex("dir");   // 0 vertical, 1 horizontal, 2 radial rings, 3 radial spokes
  boolean diff = cp5.get(Toggle.class, "diff").getState();
  int     W = canvas.width, H = canvas.height;

  PGraphics src;
  if (dir < 2) {
    if (layer == null || layer.width != W || layer.height != H) layer = createGraphics(W, H);
    src = layer;
    drawGrid(src, dir == 0, diff);
  } else {
    // RADIAL: draw the ordinary grid into an "unrolled" strip, then wrap it
    // into a disc. x -> angle (clockwise from 12 o'clock), y -> radius
    // (top of the strip = outer edge, so letters stand upright at the top).
    //   rings  = vertical layout:   columns become sectors, word heights become ring thickness
    //   spokes = horizontal layout: rows become rings, word widths become angular widths
    float inner = val("innerR");
    float R  = min(W, H) / 2.0;
    int   sw = constrain(ceil(TWO_PI * R), 16, 4096);
    int   sh = max(1, ceil(R * (1 - inner)));
    if (polarSrc == null || polarSrc.width != sw || polarSrc.height != sh) polarSrc = createGraphics(sw, sh);
    if (polarLut == null || lutW != W || lutH != H || lutSrcW != sw || lutSrcH != sh || lutInner != inner) {
      buildPolarLut(W, H, sw, sh, inner);
    }
    src = polarSrc;
    drawGrid(src, dir == 2, diff);
  }
  src.loadPixels();
  int[] sp = src.pixels;

  canvas.beginDraw();
  drawBackground(canvas);
  canvas.loadPixels();
  int[] dst = canvas.pixels;

  if (dir < 2) {
    for (int i = 0; i < dst.length; i++) {
      int c = sp[i];
      int a = c >>> 24;
      if (a == 0) continue;
      dst[i] = composite(dst[i], a, ((c >> 16) & 0xff) * a / 255, ((c >> 8) & 0xff) * a / 255, (c & 0xff) * a / 255, diff);
    }
  } else {
    int n = lutSamples;
    for (int i = 0; i < dst.length; i++) {
      int base = i * n;
      if (polarLut[base] < 0) continue;      // outside the ring: background shows
      int sa = 0, sr = 0, sg = 0, sb = 0;    // premultiplied average of sub-samples
      for (int k = 0; k < n; k++) {
        int c = sp[polarLut[base + k]];
        int a = c >>> 24;
        sa += a;
        sr += ((c >> 16) & 0xff) * a;
        sg += ((c >> 8) & 0xff) * a;
        sb += (c & 0xff) * a;
      }
      if (sa == 0) continue;
      dst[i] = composite(dst[i], sa / n, sr / (n * 255), sg / (n * 255), sb / (n * 255), diff);
    }
  }
  canvas.updatePixels();
  canvas.endDraw();
}

// a = coverage 0..255, pr/pg/pb = premultiplied letter colour
int composite(int bg, int a, int pr, int pg, int pb, boolean diff) {
  int br = (bg >> 16) & 0xff, bgG = (bg >> 8) & 0xff, bb = bg & 0xff;
  int r, g, b;
  if (diff) {                     // letters are white: |255 - bg|, weighted by coverage
    r = br  + a * (255 - 2 * br)  / 255;
    g = bgG + a * (255 - 2 * bgG) / 255;
    b = bb  + a * (255 - 2 * bb)  / 255;
  } else {                        // normal "over"
    r = pr + br  * (255 - a) / 255;
    g = pg + bgG * (255 - a) / 255;
    b = pb + bb  * (255 - a) / 255;
  }
  return 0xff000000 | (constrain(r, 0, 255) << 16) | (constrain(g, 0, 255) << 8) | constrain(b, 0, 255);
}

void drawBackground(PGraphics g) {
  int   mode = listIndex("bgGrad");   // 0 solid, 1 vertical, 2 horizontal, 3 radial
  float W = g.width, H = g.height;
  if (mode == 0) {
    g.background(pal[0]);
    return;
  }
  Graphics2D g2 = (Graphics2D) g.getNative();
  java.awt.Color c1 = awt(pal[0]), c2 = awt(pal[1]);
  if (mode == 1)      g2.setPaint(new GradientPaint(0, 0, c1, 0, H, c2));
  else if (mode == 2) g2.setPaint(new GradientPaint(0, 0, c1, W, 0, c2));
  else g2.setPaint(new RadialGradientPaint(W / 2, H / 2, max(1, sqrt(W * W + H * H) / 2),
                                          new float[] { 0, 1 }, new java.awt.Color[] { c1, c2 }));
  g2.fillRect(0, 0, (int) W, (int) H);
}

// The accordion grid, drawn as letters only on a transparent graphics.
// vertical: words stack down each column, heights breathe.
// horizontal: words sit side by side in each row, widths breathe.
void drawGrid(PGraphics g, boolean vertical, boolean diff) {
  int   rows     = max(1, round(val("rowsN")));
  int   cols     = max(1, round(val("colsN")));
  float rowOff   = val("rowOff");
  float colOff   = val("colOff");
  float spd      = val("spd");
  float easeAmt  = val("easeAmt");
  int   letterGr = listIndex("letterGrad");  // 0 off, 1 vertical, 2 horizontal
  int   gridGr   = listIndex("gridGrad");    // 0 off (colour per word), 1 columns, 2 rows, 3 diagonal

  // words cycle in order
  IntList active = new IntList();
  for (int i = 0; i < NWORDS; i++) if (wordShapes[i] != null) active.append(i);

  g.beginDraw();
  g.clear();
  Graphics2D g2 = (Graphics2D) g.getNative();
  g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
  g2.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);

  if (active.size() > 0) {
    int W = g.width, H = g.height;
    int   nStrips  = vertical ? cols : rows;
    int   nSlots   = vertical ? rows : cols;
    float stripLen = vertical ? H : W;            // length being divided
    float stripThk = (vertical ? W : H) / (float) nStrips;
    float[] wts = new float[nSlots];

    for (int s = 0; s < nStrips; s++) {
      float sum = 0;
      for (int k = 0; k < nSlots; k++) {
        int r = vertical ? k : s;
        int c = vertical ? s : k;
        float phase = t * spd + r * rowOff + c * colOff;
        wts[k] = MIN_WEIGHT + ease(0.5 + 0.5 * sin(phase), easeAmt);
        sum += wts[k];
      }

      float a0 = s * stripThk, a1 = (s + 1) * stripThk;
      float pos = 0;
      for (int k = 0; k < nSlots; k++) {
        float len = wts[k] / sum * stripLen;
        float b0 = pos, b1 = pos + len;
        pos += len;
        if (len < 0.25) continue;

        int r  = vertical ? k : s;
        int c  = vertical ? s : k;
        int wi = active.get(k % active.size());

        // slot rectangle
        float x  = vertical ? a0 : b0,  y  = vertical ? b0 : a0;
        float sw = vertical ? a1 - a0 : b1 - b0;
        float sh = vertical ? b1 - b0 : a1 - a0;

        // colour: per word, or by position in the grid
        float q;   // position along the palette, in stops (0..3, wraps)
        if (gridGr == 0) {
          q = wi;
        } else {
          float pc = cols > 1 ? c / (float) (cols - 1) : 0;
          float pr = rows > 1 ? r / (float) (rows - 1) : 0;
          float p  = gridGr == 1 ? pc : gridGr == 2 ? pr : (pc + pr) / 2;
          q = p * 3;
        }

        if (diff) {
          g2.setPaint(java.awt.Color.WHITE);
        } else if (letterGr == 0) {
          g2.setPaint(awt(paletteAt(q, gridGr != 0)));
        } else {
          // letter gradient: from this slot's colour to the next palette colour
          java.awt.Color c1 = awt(paletteAt(q, gridGr != 0));
          java.awt.Color c2 = awt(paletteAt(q + 1, true));
          if (letterGr == 1) g2.setPaint(new GradientPaint(x, y, c1, x, y + sh, c2));
          else               g2.setPaint(new GradientPaint(x, y, c1, x + sw, y, c2));
        }

        // stretch the glyph outline to fill the slot exactly
        Rectangle2D bb = wordBounds[wi];
        double sx = sw / bb.getWidth(), sy = sh / bb.getHeight();
        AffineTransform at = new AffineTransform(sx, 0, 0, sy, x - bb.getX() * sx, y - bb.getY() * sy);
        g2.fill(at.createTransformedShape(wordShapes[wi]));
      }
    }
  }
  g.endDraw();
}

// Colour at position q along the 4 word colours (q = 0..3).
// wrap = true cycles 4 -> 1, otherwise q is clamped to the ends.
color paletteAt(float q, boolean wrap) {
  if (wrap) {
    q = q % 4;
    if (q < 0) q += 4;
    int i = floor(q);
    return lerpColor(pal[2 + i % 4], pal[2 + (i + 1) % 4], q - i);
  }
  q = constrain(q, 0, 3);
  int i = min(2, floor(q));
  return lerpColor(pal[2 + i], pal[3 + i], q - i);
}

java.awt.Color awt(color c) {
  return new java.awt.Color(c, true);
}

// blend a plain sine value toward a sharper cubic ease-in-out
float ease(float x, float amt) {
  float sharp = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2;
  return lerp(x, sharp, amt);
}

// ============================================================ radial lookup

// For every canvas pixel, which strip pixel(s) land there.
// Rebuilt only when the canvas size or inner radius changes.
void buildPolarLut(int W, int H, int sw, int sh, float inner) {
  lutW = W; lutH = H; lutSrcW = sw; lutSrcH = sh; lutInner = inner;
  lutSamples = (W * H <= 1200000) ? 4 : 1;     // 2x2 supersampling unless huge
  polarLut = new int[W * H * lutSamples];
  float cx = W / 2.0, cy = H / 2.0, R = min(W, H) / 2.0, r0 = R * inner;
  float[] ox = lutSamples == 4 ? new float[] { 0.25, 0.75, 0.25, 0.75 } : new float[] { 0.5 };
  float[] oy = lutSamples == 4 ? new float[] { 0.25, 0.25, 0.75, 0.75 } : new float[] { 0.5 };

  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      int base = (y * W + x) * lutSamples;
      float pdx = x + 0.5 - cx, pdy = y + 0.5 - cy;
      float pr = sqrt(pdx * pdx + pdy * pdy);
      if (pr > R || pr < r0) {
        for (int k = 0; k < lutSamples; k++) polarLut[base + k] = -1;
        continue;
      }
      for (int k = 0; k < lutSamples; k++) {
        float dx = x + ox[k] - cx, dy = y + oy[k] - cy;
        float r = sqrt(dx * dx + dy * dy);
        float a = atan2(dy, dx) + HALF_PI;     // 0 at 12 o'clock, clockwise
        if (a < 0) a += TWO_PI;
        int sx = constrain((int) (a / TWO_PI * sw), 0, sw - 1);
        int sy = constrain((int) ((R - r) / (R - r0) * sh), 0, sh - 1);
        polarLut[base + k] = sy * sw + sx;
      }
    }
  }
}

// ============================================================ words

// Build the word's glyph outline once; bounds = tight box around the letters.
void rebuildWord(int i) {
  String s = cleanWord(words[i]);
  if (s.length() == 0) {
    wordShapes[i] = null;
    return;
  }
  Object nf = wordFont.getNative();
  java.awt.Font f = (nf instanceof java.awt.Font) ? (java.awt.Font) nf
                  : new java.awt.Font("SansSerif", java.awt.Font.BOLD, 12);
  f = f.deriveFont(FONT_SIZE);
  GlyphVector gv = f.createGlyphVector(new FontRenderContext(null, true, true), s);
  Shape outline = gv.getOutline();
  Rectangle2D b = outline.getBounds2D();
  if (b.getWidth() <= 0 || b.getHeight() <= 0) {
    wordShapes[i] = null;
    return;
  }
  wordShapes[i] = outline;
  wordBounds[i] = b;
}

// uppercase, no spaces
String cleanWord(String s) {
  return s == null ? "" : s.toUpperCase().replaceAll("\\s+", "");
}

PFont loadWordFont() {
  // 1) preferred fonts in /data
  String[] preferred = { "DieGrotesk-A-Bold.otf", "BebasNeue-Regular.ttf", "BebasNeue-Regular.otf",
                         "Oswald-Bold.ttf", "Oswald-Bold.otf", "Anton-Regular.ttf" };
  for (String f : preferred) {
    if (new File(dataPath(f)).exists()) { fontName = f; return createFont(f, FONT_SIZE, true); }
  }
  // 2) any font file in /data
  String[] list = new File(dataPath("")).list();
  if (list != null) {
    for (String f : list) {
      String lf = f.toLowerCase();
      if (lf.endsWith(".ttf") || lf.endsWith(".otf")) { fontName = f; return createFont(f, FONT_SIZE, true); }
    }
  }
  // 3) installed system fonts
  String[] sys = { "Bebas Neue", "Oswald Bold", "Oswald-Bold", "Impact", "Arial Black" };
  String[] avail = PFont.list();
  for (String want : sys) {
    for (String a : avail) {
      if (a.equalsIgnoreCase(want)) { fontName = a; return createFont(a, FONT_SIZE, true); }
    }
  }
  fontName = "SansSerif (fallback)";
  println("No font found in /data — using SansSerif");
  return createFont("SansSerif", FONT_SIZE, true);
}

// ============================================================ canvas size

void syncCanvasSize() {
  int w = round(val("cW")), h = round(val("cH"));
  if (w != canvas.width || h != canvas.height) canvas = createGraphics(w, h);
}

// ============================================================ GUI

int gy;  // running y position while laying out controls

void buildGui() {
  cp5 = new ControlP5(this);

  gy = 40;
  // ---- INPUT
  header("INPUT");
  int yInputType = gy; gy += 24;          // dropdowns are added last so they draw on top
  slider("cW",  "WIDTH",  200, 2000, 800).setDecimalPrecision(0);
  slider("cH",  "HEIGHT", 200, 2000, 800).setDecimalPrecision(0);
  slider("spd", "SPEED",  0, 6, 2);
  slider("tm",  "TIME",   0, TIME_MAX, 0);
  gy += 12;

  // ---- OUTPUT
  header("OUTPUT");
  cp5.addButton("randomize").setLabel("RANDOM").setPosition(X0, gy).setSize(120, 20);
  gy += 26;
  int yDirection = gy; gy += 24;
  slider("rowsN",   "ROWS",          1, 20, 6).setDecimalPrecision(0);
  slider("rowOff",  "ROW OFFSET",   -PI, PI, 0.7);
  slider("colsN",   "COLUMNS",       1, 20, 5).setDecimalPrecision(0);
  slider("colOff",  "COLUMN OFFSET",-PI, PI, 0.45);
  slider("easeAmt", "EASE",          0, 1, 0.5);
  slider("innerR",  "INNER RADIUS",  0, 0.9, 0.12);
  gy += 12;

  // ---- COLOR: click a swatch, edit it with the picker below
  header("COLOR");
  for (int i = 0; i < pal.length; i++) {
    cp5.addButton("sw" + i).setLabel(palLabels[i]).setPosition(X0 + i * 33, gy).setSize(29, 20);
    styleSwatch(i);
  }
  gy += 28;
  cp5.addColorPicker("picker", X0, gy, 196, 10).setColorValue(pal[selSwatch]);
  gy += 66;
  Toggle tg = cp5.addToggle("diff").setLabel("DIFFERENCE").setPosition(X0, gy).setSize(14, 14).setState(false);
  tg.getCaptionLabel().align(ControlP5.RIGHT_OUTSIDE, ControlP5.CENTER).setPaddingX(6);
  gy += 24;
  header("GRADIENTS");
  int yLetterGrad = gy; gy += 24;
  int yGridGrad   = gy; gy += 24;
  int yBgGrad     = gy; gy += 24;
  gy += 12;

  // ---- CONTENT
  header("CONTENT");
  for (int i = 0; i < NWORDS; i++) {
    Textfield tf = cp5.addTextfield("word" + i)
      .setLabel("WORD " + (i + 1) + " (3-10)")
      .setPosition(X0, gy).setSize(120, 20)
      .setText(words[i])
      .setAutoClear(false);
    tf.getCaptionLabel().align(ControlP5.RIGHT_OUTSIDE, ControlP5.CENTER).setPaddingX(6);
    gy += 26;
  }

  // dropdowns last (lowest first), so open lists draw over the controls below them
  dropdown("bgGrad",     "BACKGROUND", yBgGrad,     new String[] { "solid", "vertical", "horizontal", "radial" });
  dropdown("gridGrad",   "GRID",       yGridGrad,   new String[] { "off", "across columns", "across rows", "diagonal" });
  dropdown("letterGrad", "LETTERS",    yLetterGrad, new String[] { "off", "vertical", "horizontal" });
  dropdown("dir",        "DIRECTION",       yDirection,  new String[] { "vertical", "horizontal", "radial rings", "radial spokes" });
  dropdown("inType",     "INPUT TYPE",      yInputType,  new String[] { "animation", "static" });
}

void header(String s) {
  cp5.addTextlabel("hdr_" + s).setText(s).setPosition(X0 - 4, gy).setColorValue(color(255, 196, 0));
  gy += 18;
}

Slider slider(String name, String label, float lo, float hi, float v) {
  Slider sl = cp5.addSlider(name).setLabel(label)
    .setRange(lo, hi).setValue(v)
    .setPosition(X0, gy).setSize(120, 14);
  gy += 19;
  return sl;
}

void dropdown(String name, String label, int y, String[] items) {
  ScrollableList dd = cp5.addScrollableList(name)
    .setPosition(X0, y)
    .setSize(120, 18 * (items.length + 1))
    .setBarHeight(18).setItemHeight(18)
    .addItems(items)
    .setType(ScrollableList.DROPDOWN);
  dd.setValue(0);
  dd.close();
  cp5.addTextlabel(name + "_lbl").setText(label).setPosition(X0 + 124, y + 5);
}

// swatch button shows its colour; label flips black/white for contrast
void styleSwatch(int i) {
  Controller b = cp5.getController("sw" + i);
  color c = pal[i] | 0xff000000;
  b.setColorBackground(c);
  b.setColorForeground(c);
  b.setColorActive(c);
  b.getCaptionLabel().setColor(brightness(c) > 150 ? color(0) : color(255));
}

void controlEvent(ControlEvent e) {
  if (!guiReady) return;
  String n = e.getName();

  if (n.equals("randomize")) {
    randomizeParams();

  } else if (n.startsWith("sw")) {                 // select a swatch
    selSwatch = int(n.substring(2));
    cp5.get(ColorPicker.class, "picker").setColorValue(pal[selSwatch]);

  } else if (n.equals("picker")) {                 // edit the selected colour
    pal[selSwatch] = cp5.get(ColorPicker.class, "picker").getColorValue();
    styleSwatch(selSwatch);

  } else if (n.startsWith("word")) {
    int i = int(n.substring(4));
    Textfield tf = cp5.get(Textfield.class, n);
    String w = cleanWord(e.getStringValue());
    if (w.length() > MAX_LETTERS) {
      w = w.substring(0, MAX_LETTERS);
      warn("TRIMMED TO " + MAX_LETTERS + " LETTERS");
    }
    if (w.length() < MIN_LETTERS) {
      tf.setText(words[i]);                  // reject: put the old word back
      warn("WORDS NEED " + MIN_LETTERS + "-" + MAX_LETTERS + " LETTERS");
      return;
    }
    tf.setText(w);
    words[i] = w;
    rebuildWord(i);
  }
}

void warn(String msg) {
  warnMsg = msg;
  warnUntil = millis() + 2500;
}

void randomizeParams() {
  setVal("rowsN",   floor(random(1, 21)));
  setVal("colsN",   floor(random(1, 21)));
  setVal("rowOff",  random(-PI, PI));
  setVal("colOff",  random(-PI, PI));
  setVal("spd",     random(0.4, 4));
  setVal("easeAmt", random(1));
}

// ---- small helpers
float val(String name)             { return cp5.getController(name).getValue(); }
void  setVal(String name, float v) { cp5.getController(name).setValue(v); }
int   listIndex(String name)       { return round(cp5.get(ScrollableList.class, name).getValue()); }

boolean typing() {
  for (int i = 0; i < NWORDS; i++) {
    if (cp5.get(Textfield.class, "word" + i).isFocus()) return true;
  }
  return false;
}

// ============================================================ keys

void keyPressed() {
  if (typing()) return;  // don't trigger shortcuts while editing a word

  if (key == 'h' || key == 'H') {
    guiVisible = !guiVisible;
    if (guiVisible) cp5.show(); else cp5.hide();
  } else if (key == 's' || key == 'S') {
    String f = "frame-" + nf(frameCount, 4) + ".png";
    canvas.save(savePath(f));
    println("saved " + f);
  } else if (key == 'r' || key == 'R') {
    recording = !recording;
    println(recording ? "recording to /frames ..." : "recording stopped (" + recFrame + " frames)");
  }
}
