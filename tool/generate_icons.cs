using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Collections.Generic;

public class CloudoraIconGenerator {
    private static void SaveImage(Bitmap mark, int w, int h, double scale, Color? bg, string path, ImageFormat fmt) {
        string dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) {
            Directory.CreateDirectory(dir);
        }
        using (Bitmap bmp = RenderOnCanvas(mark, w, h, scale, bg)) {
            if (fmt == ImageFormat.Jpeg) {
                ImageCodecInfo jpgEncoder = GetEncoder(ImageFormat.Jpeg);
                EncoderParameters myEncoderParameters = new EncoderParameters(1);
                myEncoderParameters.Param[0] = new EncoderParameter(Encoder.Quality, 92L);
                bmp.Save(path, jpgEncoder, myEncoderParameters);
            } else {
                bmp.Save(path, fmt);
            }
        }
    }

    private static Bitmap RenderOnCanvas(Bitmap mark, int targetW, int targetH, double scale, Color? bg) {
        Bitmap bmp = new Bitmap(targetW, targetH, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            if (bg.HasValue) {
                g.Clear(bg.Value);
            } else {
                g.Clear(Color.Transparent);
            }

            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;

            int markSize = Math.Max(mark.Width, mark.Height);
            int shortest = Math.Min(targetW, targetH);
            double factor = (shortest * scale) / markSize;

            int drawW = (int)Math.Round(mark.Width * factor);
            int drawH = (int)Math.Round(mark.Height * factor);
            int destX = (targetW - drawW) / 2;
            int destY = (targetH - drawH) / 2;

            g.DrawImage(mark, new Rectangle(destX, destY, drawW, drawH));
        }
        return bmp;
    }

    private static ImageCodecInfo GetEncoder(ImageFormat format) {
        ImageCodecInfo[] codecs = ImageCodecInfo.GetImageEncoders();
        foreach (ImageCodecInfo codec in codecs) {
            if (codec.FormatID == format.Guid) return codec;
        }
        return null;
    }

    public static void GenerateAll(string uploadedPath, string projectRoot) {
        Console.WriteLine("Step 1: Extracting clean transparent cloud mark...");
        Bitmap cleanMark;
        Bitmap monoMark;

        using (Bitmap src = new Bitmap(uploadedPath)) {
            int w = src.Width;
            int h = src.Height;

            bool[,] isBg = new bool[w, h];
            Queue<Point> q = new Queue<Point>();

            for (int x = 0; x < w; x++) {
                q.Enqueue(new Point(x, 0));
                q.Enqueue(new Point(x, h - 1));
            }
            for (int y = 0; y < h; y++) {
                q.Enqueue(new Point(0, y));
                q.Enqueue(new Point(w - 1, y));
            }

            int[] dx = new int[] { -1, 1, 0, 0, -1, -1, 1, 1 };
            int[] dy = new int[] { 0, 0, -1, 1, -1, 1, -1, 1 };

            while (q.Count > 0) {
                Point p = q.Dequeue();
                if (p.X < 0 || p.X >= w || p.Y < 0 || p.Y >= h) continue;
                if (isBg[p.X, p.Y]) continue;

                Color c = src.GetPixel(p.X, p.Y);
                if (c.R >= 248 && c.G >= 248 && c.B >= 248) {
                    isBg[p.X, p.Y] = true;
                    for (int i = 0; i < 8; i++) {
                        int nx = p.X + dx[i];
                        int ny = p.Y + dy[i];
                        if (nx >= 0 && nx < w && ny >= 0 && ny < h && !isBg[nx, ny]) {
                            q.Enqueue(new Point(nx, ny));
                        }
                    }
                }
            }

            Bitmap extracted = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            Bitmap monoExtracted = new Bitmap(w, h, PixelFormat.Format32bppArgb);

            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (isBg[x, y]) {
                        extracted.SetPixel(x, y, Color.FromArgb(0, 0, 0, 0));
                        monoExtracted.SetPixel(x, y, Color.FromArgb(0, 0, 0, 0));
                        continue;
                    }

                    Color c = src.GetPixel(x, y);
                    bool touchesBg = false;
                    for (int i = 0; i < 8; i++) {
                        int nx = x + dx[i];
                        int ny = y + dy[i];
                        if (nx >= 0 && nx < w && ny >= 0 && ny < h && isBg[nx, ny]) {
                            touchesBg = true;
                            break;
                        }
                    }

                    int a = 255;
                    int r = c.R, g = c.G, b = c.B;

                    if (touchesBg) {
                        double minVal = Math.Min(c.R, Math.Min(c.G, c.B));
                        double alphaNorm = Math.Pow(1.0 - (minVal / 255.0), 0.85);

                        if (alphaNorm <= 0.05) {
                            a = 0;
                        } else {
                            a = (int)Math.Round(Math.Min(255.0, Math.Max(0.0, alphaNorm * 255.0)));
                            double factor = a / 255.0;
                            r = (int)Math.Round(Math.Min(255.0, Math.Max(0.0, (c.R - (1.0 - factor) * 255.0) / factor)));
                            g = (int)Math.Round(Math.Min(255.0, Math.Max(0.0, (c.G - (1.0 - factor) * 255.0) / factor)));
                            b = (int)Math.Round(Math.Min(255.0, Math.Max(0.0, (c.B - (1.0 - factor) * 255.0) / factor)));
                        }
                    }

                    extracted.SetPixel(x, y, Color.FromArgb(a, r, g, b));

                    if (a > 0 && c.R > 240 && c.G > 240 && c.B > 240) {
                        monoExtracted.SetPixel(x, y, Color.FromArgb(0, 0, 0, 0));
                    } else {
                        monoExtracted.SetPixel(x, y, Color.FromArgb(a, 255, 255, 255));
                    }
                }
            }

            int minX = w, minY = h, maxX = 0, maxY = 0;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (extracted.GetPixel(x, y).A > 0) {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            int cropW = maxX - minX + 1;
            int cropH = maxY - minY + 1;
            Rectangle cropRect = new Rectangle(minX, minY, cropW, cropH);

            cleanMark = new Bitmap(cropW, cropH, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(cleanMark)) {
                g.DrawImage(extracted, 0, 0, cropRect, GraphicsUnit.Pixel);
            }

            monoMark = new Bitmap(cropW, cropH, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(monoMark)) {
                g.DrawImage(monoExtracted, 0, 0, cropRect, GraphicsUnit.Pixel);
            }

            extracted.Dispose();
            monoExtracted.Dispose();
        }

        Console.WriteLine(string.Format("Clean mark size: {0}x{1}", cleanMark.Width, cleanMark.Height));

        string sourceDir = Path.Combine(projectRoot, "tool", "icon", "source");
        if (!Directory.Exists(sourceDir)) Directory.CreateDirectory(sourceDir);
        string masterPath = Path.Combine(sourceDir, "cloudora.png");
        using (Bitmap master = RenderOnCanvas(cleanMark, 2048, 2048, 0.90, null)) {
            master.Save(masterPath, ImageFormat.Png);
        }

        Console.WriteLine("Step 2: Generating Brand & App Assets...");
        string brandMarkPath = Path.Combine(projectRoot, "assets", "brand", "mark.png");
        SaveImage(cleanMark, 512, 512, 0.88, null, brandMarkPath, ImageFormat.Png);

        string channelPhotoPath = Path.Combine(projectRoot, "assets", "brand", "channel_photo.jpg");
        SaveImage(cleanMark, 640, 640, 0.54, Color.FromArgb(255, 0xEA, 0xF1, 0xFF), channelPhotoPath, ImageFormat.Jpeg);

        string outDir = Path.Combine(projectRoot, "tool", "icon", "out");
        SaveImage(cleanMark, 512, 512, 0.88, null, Path.Combine(outDir, "mark.png"), ImageFormat.Png);
        SaveImage(cleanMark, 1024, 1024, 0.64, Color.White, Path.Combine(outDir, "icon.png"), ImageFormat.Png);
        SaveImage(cleanMark, 1024, 1024, 0.64, null, Path.Combine(outDir, "foreground.png"), ImageFormat.Png);
        SaveImage(cleanMark, 640, 640, 0.54, Color.FromArgb(255, 0xEA, 0xF1, 0xFF), Path.Combine(outDir, "channel_photo.png"), ImageFormat.Png);
        SaveImage(monoMark, 1024, 1024, 0.86, null, Path.Combine(outDir, "notification.png"), ImageFormat.Png);

        using (Bitmap bgBmp = new Bitmap(1024, 1024)) {
            using (Graphics g = Graphics.FromImage(bgBmp)) g.Clear(Color.White);
            bgBmp.Save(Path.Combine(outDir, "background.png"), ImageFormat.Png);
        }

        Console.WriteLine("Step 3: Generating Android Mipmaps & Drawables...");
        string resDir = Path.Combine(projectRoot, "android", "app", "src", "main", "res");

        Dictionary<string, int> mipmaps = new Dictionary<string, int>();
        mipmaps.Add("mipmap-mdpi", 48);
        mipmaps.Add("mipmap-hdpi", 72);
        mipmaps.Add("mipmap-xhdpi", 96);
        mipmaps.Add("mipmap-xxhdpi", 144);
        mipmaps.Add("mipmap-xxxhdpi", 192);

        foreach (KeyValuePair<string, int> kvp in mipmaps) {
            string p = Path.Combine(resDir, kvp.Key, "ic_launcher.png");
            SaveImage(cleanMark, kvp.Value, kvp.Value, 0.64, Color.White, p, ImageFormat.Png);
        }

        Dictionary<string, int[]> drawables = new Dictionary<string, int[]>();
        drawables.Add("drawable-mdpi", new int[] { 108, 24 });
        drawables.Add("drawable-hdpi", new int[] { 162, 36 });
        drawables.Add("drawable-xhdpi", new int[] { 216, 48 });
        drawables.Add("drawable-xxhdpi", new int[] { 324, 72 });
        drawables.Add("drawable-xxxhdpi", new int[] { 432, 96 });

        foreach (KeyValuePair<string, int[]> kvp in drawables) {
            string d = Path.Combine(resDir, kvp.Key);
            int adaptSize = kvp.Value[0];
            int notifSize = kvp.Value[1];

            using (Bitmap bg = new Bitmap(adaptSize, adaptSize)) {
                using (Graphics g = Graphics.FromImage(bg)) g.Clear(Color.White);
                bg.Save(Path.Combine(d, "ic_launcher_background.png"), ImageFormat.Png);
            }

            SaveImage(cleanMark, adaptSize, adaptSize, 0.64, null, Path.Combine(d, "ic_launcher_foreground.png"), ImageFormat.Png);
            SaveImage(monoMark, adaptSize, adaptSize, 0.64, null, Path.Combine(d, "ic_launcher_monochrome.png"), ImageFormat.Png);
            SaveImage(monoMark, notifSize, notifSize, 0.86, null, Path.Combine(d, "ic_stat_cloudora.png"), ImageFormat.Png);
        }

        Console.WriteLine("Step 4: Generating iOS Icons...");
        string iosDir = Path.Combine(projectRoot, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset");
        if (Directory.Exists(iosDir)) {
            Dictionary<string, int> iosSizes = new Dictionary<string, int>();
            iosSizes.Add("Icon-App-1024x1024@1x.png", 1024);
            iosSizes.Add("Icon-App-20x20@1x.png", 20);
            iosSizes.Add("Icon-App-20x20@2x.png", 40);
            iosSizes.Add("Icon-App-20x20@3x.png", 60);
            iosSizes.Add("Icon-App-29x29@1x.png", 29);
            iosSizes.Add("Icon-App-29x29@2x.png", 58);
            iosSizes.Add("Icon-App-29x29@3x.png", 87);
            iosSizes.Add("Icon-App-40x40@1x.png", 40);
            iosSizes.Add("Icon-App-40x40@2x.png", 80);
            iosSizes.Add("Icon-App-40x40@3x.png", 120);
            iosSizes.Add("Icon-App-50x50@1x.png", 50);
            iosSizes.Add("Icon-App-50x50@2x.png", 100);
            iosSizes.Add("Icon-App-57x57@1x.png", 57);
            iosSizes.Add("Icon-App-57x57@2x.png", 114);
            iosSizes.Add("Icon-App-60x60@2x.png", 120);
            iosSizes.Add("Icon-App-60x60@3x.png", 180);
            iosSizes.Add("Icon-App-72x72@1x.png", 72);
            iosSizes.Add("Icon-App-72x72@2x.png", 144);
            iosSizes.Add("Icon-App-76x76@1x.png", 76);
            iosSizes.Add("Icon-App-76x76@2x.png", 152);
            iosSizes.Add("Icon-App-83.5x83.5@2x.png", 167);

            foreach (KeyValuePair<string, int> kvp in iosSizes) {
                SaveImage(cleanMark, kvp.Value, kvp.Value, 0.64, Color.White, Path.Combine(iosDir, kvp.Key), ImageFormat.Png);
            }
        }

        Console.WriteLine("Step 5: Generating Web / Docs Assets...");
        string docsDir = Path.Combine(projectRoot, "docs", "assets");
        if (Directory.Exists(docsDir)) {
            SaveImage(cleanMark, 180, 180, 0.64, Color.White, Path.Combine(docsDir, "apple-touch-icon.png"), ImageFormat.Png);
            SaveImage(cleanMark, 32, 32, 0.75, Color.White, Path.Combine(docsDir, "favicon-32.png"), ImageFormat.Png);
            SaveImage(cleanMark, 512, 512, 0.64, Color.White, Path.Combine(docsDir, "brand", "app-icon.png"), ImageFormat.Png);
            SaveImage(cleanMark, 192, 192, 0.64, Color.White, Path.Combine(docsDir, "brand", "icon-192.png"), ImageFormat.Png);
        }

        cleanMark.Dispose();
        monoMark.Dispose();
        Console.WriteLine("ALL ICONS AND BRAND ASSETS SUCCESSFULLY GENERATED!");
    }
}
