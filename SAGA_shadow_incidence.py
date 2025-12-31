import os
import sys
import subprocess
import datetime

# --- KONFIGURATION ---
SAGA_CMD = r"C:\legacySW\shadow_solar_calculator\saga\saga-9.11.0_msw\saga_cmd.exe"

def run_saga_analysis(timestamp_str, dem_input, out_dir):
    # 1. Validierung
    if not os.path.exists(dem_input):
        print(f"Error: DEM file '{dem_input}' not found.")
        return

    # Ausgabeverzeichnis erstellen
    if not os.path.exists(out_dir):
        os.makedirs(out_dir)
        print(f"Created directory: {out_dir}")

    # Zeitstempel parsen
    try:
        dt = datetime.datetime.strptime(timestamp_str, "%Y%m%dt%H%M")
    except ValueError:
        print("Error: Timestamp format must be YYYYMMDDtHHMM (e.g., 20210602t1005)")
        return
    
    saga_date = dt.strftime("%Y-%m-%d")
    saga_time = dt.hour + dt.minute / 60.0
    
    # Pfade für Outputs zusammenbauen
    base_name = os.path.splitext(os.path.basename(dem_input))[0]
    out_shadow = os.path.join(out_dir, f"shadow_{timestamp_str}_{base_name}.tif")
    out_angle = os.path.join(out_dir, f"angle_{timestamp_str}_{base_name}.tif")

    print(f"\n--- SAGA Analysis ---")
    print(f"DEM:      {dem_input}")
    print(f"Out Dir:  {out_dir}")
    print(f"Date/Time: {saga_date} at {dt.strftime('%H:%M')}")

    # 1. WURFSCHATTEN (METHOD 3: Shadows Only)
    print("Calculating Shadow Mask...")
    cmd_shadow = [
        SAGA_CMD, "ta_lighting", "0",
        "-ELEVATION", dem_input,
        "-SHADE", out_shadow,
        "-METHOD", "3",
        "-POSITION", "1",
        "-DATE", saga_date,
        "-TIME", str(saga_time),
        "-UNIT", "1"
    ]
    subprocess.run(cmd_shadow)

    # 2. EINFALLSWINKEL (METHOD 1: Standard)
    print("Calculating Solar Incidence Angle...")
    cmd_angle = [
        SAGA_CMD, "ta_lighting", "0",
        "-ELEVATION", dem_input,
        "-SHADE", out_angle,
        "-METHOD", "1", #1 = Standard (max. 90 Degree)
        "-POSITION", "1",
        "-DATE", saga_date,
        "-TIME", str(saga_time),
        "-UNIT", "1"
    ]
    subprocess.run(cmd_angle)

    print(f"\nFinished!")
    print(f"Results saved in: {os.path.abspath(out_dir)}")

if __name__ == "__main__":
    # Erwartet 3 Argumente: Zeitstempel, DEM-Pfad, Output-Ordner
    if len(sys.argv) < 4:
        print("Usage: python SAGA_shadow_incidence <timestamp> <dem_path> <out_dir>")
        print("Example: python SAGA_shadow_incidence 20210602t1005 LIDAR_MAX_subset_engadin.tif ./output_results")
    else:
        run_saga_analysis(sys.argv[1], sys.argv[2], sys.argv[3])