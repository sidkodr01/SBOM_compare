import pandas as pd

# File paths
input_file = "SBOM_Version_Comparison_Result.xlsx"
output_file = "sbom_comparison_with_summary.xlsx"

# Load input file
df = pd.read_excel(input_file)

# Clean and derive flags
def has_value(x): return pd.notna(x) and str(x).strip() != ""

df['Is_UBI'] = df['Detected Base Image'].str.lower().str.contains('ubi', na=False)
df['Is_Java'] = df['Detected Java Version'].apply(has_value)
df['Has_Tomcat'] = df['Detected Tomcat Version'].apply(has_value)
df['Has_SpringBoot'] = df['Detected Spring Boot Version'].apply(has_value)

df['Java_With_Tomcat_Spring'] = df['Is_Java'] & (df['Has_Tomcat'] | df['Has_SpringBoot'])
df['Java_Without_Tomcat_Spring'] = df['Is_Java'] & ~(df['Has_Tomcat'] | df['Has_SpringBoot'])
df['Non_Java'] = ~df['Is_Java']

df['Java_With_Tomcat_Spring_OK'] = df['Java_With_Tomcat_Spring'] & (df['STATUS'] == 'MATCH')
df['Java_Without_Tomcat_Spring_OK'] = df['Java_Without_Tomcat_Spring'] & (df['STATUS'] == 'MATCH')
df['Non_Java_OK'] = df['Non_Java'] & (df['STATUS'] == 'MATCH')

# Highlight MISMATCH + missing Tomcat/SpringBoot
df['Anomaly Reason'] = ''
mask = (df['STATUS'] == 'MISMATCH') & (~df['Has_Tomcat']) & (~df['Has_SpringBoot'])
df.loc[mask, 'Anomaly Reason'] = 'MISMATCH and missing Spring Boot/Tomcat'

# Summary values
total = len(df)
ubi = df['Is_UBI'].sum()
ubi_ok = df[df['Is_UBI'] & (df['STATUS'] == 'MATCH')].shape[0]
java_tomcat_ok = df['Java_With_Tomcat_Spring_OK'].sum()
java_tomcat_total = df['Java_With_Tomcat_Spring'].sum()
java_no_tomcat_ok = df['Java_Without_Tomcat_Spring_OK'].sum()
non_java_ok = df['Non_Java_OK'].sum()
mismatch_missing_framework = df['Anomaly Reason'].eq('MISMATCH and missing Spring Boot/Tomcat').sum()

# Build summary table
summary_data = [
    ['Total Images', total],
    ['UBI Migrated Images', ubi],
    ['UBI "Lineup OK" Images', ubi_ok],
    ['Java images with Tomcat/SpringBoot "lineup OK"', java_tomcat_ok],
    ['Total Java images with Tomcat/SpringBoot', java_tomcat_total],
    ['Java images without Tomcat/SpringBoot "lineup OK"', java_no_tomcat_ok],
    ['Non-Java images "lineup OK"', non_java_ok],
    ['Images with MISMATCH and missing Spring Boot/Tomcat', mismatch_missing_framework],
    ['UBI %', f"{(ubi / total * 100):.0f}%"],
    ['UBI "lineup OK" %', f"{(ubi_ok / ubi * 100):.0f}%" if ubi > 0 else "0%"],
    ['Java with Tomcat/SpringBoot "lineup OK" %', f"{(java_tomcat_ok / java_tomcat_total * 100):.0f}%" if java_tomcat_total > 0 else "0%"],
    ['Java without Tomcat/SpringBoot "lineup OK" %', f"{(java_no_tomcat_ok / df['Java_Without_Tomcat_Spring'].sum() * 100):.2f}%" if df['Java_Without_Tomcat_Spring'].sum() > 0 else "0%"],
]

summary_df = pd.DataFrame(summary_data, columns=["Metric", "Value"])

# Save to Excel with 2 sheets
with pd.ExcelWriter(output_file, engine='openpyxl') as writer:
    df.to_excel(writer, index=False, sheet_name="SBOM Comparison")
    summary_df.to_excel(writer, index=False, sheet_name="Summary")

print(f"✅ Final Excel with summary + anomaly column saved to: {output_file}")
