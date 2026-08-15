#!/usr/bin/env bash
# Re-download the boundary data. Already committed under data/, so this is only
# needed to refresh it (e.g. when the ICB geography changes again).
#
# Source: ONS Open Geography Portal, Open Government Licence v3.
# BGC = generalised (20 m) and clipped to the coastline, which is what we want:
# unclipped boundaries run out to mean low water and look wrong extruded.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p data

base="https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services"
query="query?where=1%3D1&outFields=*&outSR=4326&f=geojson"

# 36 Integrated Care Boards (England only, April 2026 geography)
curl -fsSL -o data/icb.json \
	"$base/Integrated_Care_Boards_April_2026_Boundaries_EN_BGC/FeatureServer/0/$query"

# UK country outlines; England is dropped at build time in favour of the ICBs
curl -fsSL -o data/countries.json \
	"$base/Countries_December_2024_Boundaries_UK_BGC/FeatureServer/0/$query"

# NHS England, Patients Registered at a GP Practice (monthly). Carries the same
# E54... ONS codes as the boundaries, so registered-patient counts and GP
# practice counts join exactly. Find the current month's file URLs at
# https://digital.nhs.uk/data-and-information/publications/statistical/patients-registered-at-a-gp-practice
mkdir -p data/nhs
nhs="https://files.digital.nhs.uk"
curl -fsSL -o data/nhs/gp-reg-pat-prac-sing-age-regions.zip \
	"$nhs/14/D21F56/gp-reg-pat-prac-sing-age-regions.zip"
curl -fsSL -o data/nhs/gp-reg-pat-prac-map.zip \
	"$nhs/26/656B2E/gp-reg-pat-prac-map.zip"

echo "fetched:"
ls -lh data/icb.json data/countries.json data/nhs/*.zip
