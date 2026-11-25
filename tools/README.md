# tools (not part of the addon zip)

`gen_questitemdb.py` regenerates `QuestItemDB.lua` from a QuestieDB Forever release
(`QuestieDB-<ver>-Forever.zip`, baked TOC metadata store, CBOR rows). Needs Python 3 and `cbor2`.
Edit the TOC path in `questitemdb_decode.py` and the output path in `gen_questitemdb.py`, then run
`python gen_questitemdb.py`. Data license: see the "Data source and license" part of the main README.
