#!/bin/bash

# List of resource file basenames (update if you have more)
FILES=(
  "validation_results.txt"
  "verification_report.md"
  "test_summary_report.md"
  "test_results_template.md"
  "test_file"
  "test_execution_plan.md"
  "mock_test_report.md"
)

PBXPROJ="Signal.xcodeproj/project.pbxproj"
TMPFILE="${PBXPROJ}.tmp"

cp "$PBXPROJ" "$TMPFILE"

for FILE in "${FILES[@]}"; do
  # Remove lines referencing the file by name
  sed -i '' "/$FILE/d" "$TMPFILE"
done

# Overwrite the original project file
mv "$TMPFILE" "$PBXPROJ"

echo "Removed references to missing resource files from $PBXPROJ"