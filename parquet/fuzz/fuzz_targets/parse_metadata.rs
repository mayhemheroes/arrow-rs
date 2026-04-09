#![no_main]
use libfuzzer_sys::fuzz_target;
use parquet::file::metadata::ParquetMetaDataReader;
fuzz_target!(|data: &[u8]| {    
    let _ = ParquetMetaDataReader::decode_metadata(data);
});
