#!/usr/bin/env python3
"""Build the offline Singapore catalog from LTA XLS/shapefile and CEPAS aliases.

Requires xlrd, pyshp, pyproj. Input downloads are explicit; app builds never
refresh this data. Station points are centroids of LTA station footprints.
"""
import argparse
import collections
import csv
import hashlib
import io
import json
import re
from pathlib import Path
import zipfile


def build(names_zip, stations_zip, aliases_csv, boundary_json):
    import xlrd
    import shapefile
    import pyproj
    with zipfile.ZipFile(names_zip) as archive:
        member = next(n for n in archive.namelist() if n.endswith('.xls'))
        sheet = xlrd.open_workbook(file_contents=archive.read(member)).sheet_by_index(0)
        names = {str(sheet.cell_value(i, 0)).strip(): {
            'name': str(sheet.cell_value(i, 1)).strip(),
            'nameZh': str(sheet.cell_value(i, 2)).strip(),
        } for i in range(1, sheet.nrows)}
    locations = collections.defaultdict(list)
    with zipfile.ZipFile(stations_zip) as archive:
        stem = next(n[:-4] for n in archive.namelist() if n.endswith('.shp'))
        reader = shapefile.Reader(**{ext: io.BytesIO(archive.read(stem+'.'+ext)) for ext in ('shp', 'shx', 'dbf')})
        transform = pyproj.Transformer.from_crs(pyproj.CRS.from_wkt(archive.read(stem+'.prj').decode()), 'EPSG:4326', always_xy=True)
        for record in reader.iterShapeRecords():
            shape = record.shape
            parts = list(shape.parts) + [len(shape.points)]
            area = cx = cy = 0.0
            for start, end in zip(parts, parts[1:]):
                ring = shape.points[start:end]
                for a, b in zip(ring, ring[1:]+ring[:1]):
                    cross = a[0]*b[1]-b[0]*a[1]
                    area += cross; cx += (a[0]+b[0])*cross; cy += (a[1]+b[1])*cross
            if not area: continue
            point = transform.transform(cx/(3*area), cy/(3*area))
            # Modern LTA files combine some interchange codes in STN_NAM.
            for code in re.split(r'\s*/\s*', record.record.as_dict()['STN_NAM']):
                locations[code].append(point)
    grouped = collections.defaultdict(list)
    for code, name in names.items(): grouped[name['name']].append(code)
    stations = []
    station_for_public_code = {}
    for name, codes in sorted(grouped.items()):
        points = sorted(set(p for c in codes for p in locations[c]))
        if not points: continue
        identifier = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
        station = dict(id=identifier, name=name, nameZh=names[codes[0]]['nameZh'], publicCodes=sorted(codes),
                       latitude=round(sum(p[1] for p in points)/len(points), 6),
                       longitude=round(sum(p[0] for p in points)/len(points), 6))
        if not 1.1 < station['latitude'] < 1.6 or not 103.5 < station['longitude'] < 104.2:
            raise ValueError('Station outside Singapore: '+name)
        stations.append(station)
        for code in codes: station_for_public_code[code] = identifier
    aliases = {}
    for row in csv.DictReader(Path(aliases_csv).read_text().splitlines()):
        code = row['id'].strip()
        identifier = station_for_public_code.get(row['code'].strip())
        if not identifier: continue
        if code in aliases and aliases[code] != identifier:
            raise ValueError('Conflicting CEPAS alias: '+code)
        aliases[code] = identifier
    feature = json.loads(Path(boundary_json).read_text())
    geometry = feature['geometry']
    polygons = geometry['coordinates'] if geometry['type'] == 'MultiPolygon' else [geometry['coordinates']]
    components = [dict(outer=rings[0], holes=rings[1:]) for rings in polygons]
    points = [p for component in components for p in component['outer']]
    bbox = [min(p[0] for p in points), min(p[1] for p in points), max(p[0] for p in points), max(p[1] for p in points)]
    sources = [
        ('LTA Train Station Codes and Chinese Names (Jan 2025)', names_zip, 'https://datamall.lta.gov.sg/content/dam/datamall/datasets/Geospatial/Train%20Station%20Codes%20and%20Chinese%20Names.zip'),
        ('LTA TrainStation (Sep 2026)', stations_zip, 'https://datamall.lta.gov.sg/content/dam/datamall/datasets/Geospatial/TrainStation_Sep2026.zip'),
        ('Metrodroid CEPAS station aliases', aliases_csv, 'https://github.com/metrodroid/metrodroid/blob/master/data/ezlink/mapping.csv'),
        ('Natural Earth 1:10m Singapore boundary', boundary_json, 'https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_10m_admin_0_countries.geojson'),
    ]
    return dict(version=1, stations=stations, aliases=dict(sorted(aliases.items())),
                country=dict(id='sg:country', name='Singapore', nameZh='新加坡', center=[103.8198, 1.3521], bbox=bbox, components=components),
                sources=[dict(title=title, url=url, sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest()) for title,path,url in sources],
                attribution='Contains information from LTA Train Station Codes and Chinese Names and TrainStation, accessed 2026-10-31, under the Singapore Open Data Licence v1.0. Country outline: Natural Earth (public domain).',
                licenseURL='https://datamall.lta.gov.sg/content/datamall/en/SingaporeOpenDataLicence.html')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('names-zip', 'stations-zip', 'aliases-csv', 'boundary-json'): p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=Path('data/stations/SingaporeTransit.json'))
    args = p.parse_args()
    result = build(args.names_zip, args.stations_zip, args.aliases_csv, args.boundary_json)
    args.output.write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(',', ':'))+'\n')
    print(f"{len(result['stations'])} station groups; {len(result['aliases'])} CEPAS aliases")

if __name__ == '__main__': main()
