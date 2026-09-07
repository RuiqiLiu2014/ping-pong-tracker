import subprocess, sys, os

CHROME = "google-chrome"
DIR = os.path.dirname(os.path.abspath(__file__))

def render(svg_path, out_prefix):
    with open(svg_path) as f:
        svg = f.read()
    modes = {
        "light": ("#ffffff", "#111111"),   # bg, line color
        "dark":  ("#0b0b0b", "#f2f2f2"),
    }
    for mode, (bg, col) in modes.items():
        html = (
            "<!doctype html><html><head><meta charset='utf-8'>"
            "<style>html,body{margin:0;padding:0}"
            f"body{{background:{bg};color:{col};"
            "display:flex;align-items:center;justify-content:center;"
            "width:900px;height:640px}}</style></head><body>"
            f"{svg}</body></html>"
        )
        html_path = os.path.join(DIR, f"_{out_prefix}_{mode}.html")
        png_path = os.path.join(DIR, f"{out_prefix}_{mode}.png")
        with open(html_path, "w") as f:
            f.write(html)
        subprocess.run([
            CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=1",
            f"--screenshot={png_path}", "--window-size=900,640",
            html_path,
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.remove(html_path)
        print(png_path)

if __name__ == "__main__":
    for pair in sys.argv[1:]:
        svg, prefix = pair.split("::")
        render(svg, prefix)
