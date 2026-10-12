find . -type d -empty -not -path '*/.*' | while read -r dir; do
     echo "rstelle README.md in: $dir"
     echo "# Ordnerplatzhalter" > "$dir/README.md"
     echo "Dieser Ordner wr durch diese README-Datei auf github behalten." >> "$dir/README.md"
done
