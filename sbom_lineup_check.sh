#!/bin/bash

# ------------------------------------------------------------------
# Script: SBOM Lineup Compliance Checker (CI/CD Ready)
# Purpose:
#   1. Read image list from input file
#   2. Extract SBOM metadata using cosign + jq
#   3. Normalize + deduplicate package data
#   4. Parse versions of base image, tomcat, springboot, java
#   5. Generate Excel summary report (via embedded Python)
# ------------------------------------------------------------------

# Input file with lines: <Product_Name> <Image_Name>
IN="container_list_with_product_5.4_20250625.txt"

# Final report output Excel file
OUT="sbom_summary_fixed.xlsx"

# Temporary directory to store intermediate CSVs
TMP_DIR="tmp_sbom_parts"

# Clean temporary directory before starting
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# --------------------------
# Step 1: Loop through each line (product and image)
# --------------------------
while read -r PROD IMG; do
  # Skip if line is blank or image has no tag (no colon)
  [[ -z "$IMG" || "$IMG" != *:* ]] && { echo "[WARN] Skipping invalid line: $IMG"; continue; }

  # Sanitize image name to use as filename
  SAFE_NAME=$(echo "$IMG" | sed 's/[^A-Za-z0-9]/_/g')
  OUTCSV="$TMP_DIR/${SAFE_NAME}.csv"

  echo "[INFO] Processing $IMG → $PROD"

  # --------------------------
  # Step 2: Use cosign to verify and extract SBOM
  # --------------------------
  cosign verify-attestation --key ~/mycom-ecr.pub --insecure-ignore-tlog "$IMG" 2>/dev/null \
    | jq -r '.payload' \
    | base64 -d \
    | jq -r '.predicate.Data' \
    | jq -r --arg img "$IMG" --arg prod "$PROD" '
        . | if type == "string" then fromjson else . end | .packages[] |
        "\($prod),\($img),\(.name),\(.versionInfo),\(.externalRefs[]? | select(.) | .referenceLocator),\(.licenseDeclared)"' \
    | sed -E \
        -e 's/\(?LicenseRef[^[:space:]]*Apache[^[:space:]]*/Apache-2.0/Ig' \
        -e 's/LicenseRef-.*MIT.*/MIT/Ig' \
        -e 's/LicenseRef-[0-9a-f]{64}//g' \
    | awk -F',' '
        {
          key3=$1 FS $2 FS $3
          key4=$1 FS $2 FS $3 FS $4
          if (!(key3 in seen3) || ((key4 in seen4) && length($5) > 0)) {
            seen3[key3]=1
            seen4[key4]=1
            lines[key4]=$0
          }
        }
        END {
          for (k in lines) print lines[k]
        }' \
    | sort > "$OUTCSV"
done < "$IN"

# --------------------------
# Step 3: Post-process using Python
# Extract required components: base image, tomcat, springboot, java
# --------------------------
python3 <<EOF
import pandas as pd, os, re

tmp = "$TMP_DIR"
rows = []

# --------------------------
# Function: Extract clean version number (e.g., 3.0.1 from "tomcat-embed-core-3.0.1.jar")
# --------------------------
def clean_ver(s):
    m = re.search(r'(\d+\.\d+(?:\.\d+)?(?:[-\.]?[A-Za-z0-9]*)?)', s)
    return m.group(1) if m else ""

# --------------------------
# Step 4: Loop through each intermediate CSV
# --------------------------
for f in os.listdir(tmp):
    if not f.endswith(".csv"): continue
    df = pd.read_csv(os.path.join(tmp,f), header=None,
                     names=["Product","Image","Package","Version","Locator","License"])
    if df.empty: continue

    img = df.at[0,"Image"]

    # Extract base image version from "redhat-release"
    base = ""
    redhat = df[df["Package"] == "redhat-release"]
    if not redhat.empty:
        base = redhat["Version"].values[0]

    # Extract Tomcat version
    tomcat=""
    for pkg,ver in zip(df["Package"],df["Version"]):
        if str(pkg).lower().startswith("tomcat"):
            tomcat=clean_ver(str(ver)); break

    # Extract Spring Boot version (match package or locator)
    spring=""
    for pkg,ver,loc in zip(df["Package"],df["Version"],df["Locator"]):
        text=(str(pkg)+" "+str(loc)).lower()
        if "spring-boot-starter" in text or "org.springframework.boot" in text:
            spring=clean_ver(str(ver)); break

    # Extract Java version (search from all version+locator strings)
    java=""
    alltxt=" ".join(df["Version"].fillna("").astype(str))+" ".join(df["Locator"].fillna("").astype(str))
    mj=re.search(r'21\.0\.\d+', alltxt)  # You can extend this regex to catch 17.x, 11.x if needed
    if mj: java=mj.group(0)

    # Append row
    rows.append({
      "Product": df.at[0,"Product"],
      "Image": img,
      "Detected Base Image": base,
      "Detected Tomcat Version": tomcat,
      "Detected Spring Boot Version": spring,
      "Detected Java Version": java
    })

# --------------------------
# Step 5: Write final report
# --------------------------
out = pd.DataFrame(rows, columns=[
    "Product","Image",
    "Detected Base Image",
    "Detected Tomcat Version",
    "Detected Spring Boot Version",
    "Detected Java Version"])

out.to_excel("${OUT}", index=False)
EOF

# --------------------------
# End of script
# --------------------------
echo "[INFO] SBOM lineup check complete. Output: ${OUT}"