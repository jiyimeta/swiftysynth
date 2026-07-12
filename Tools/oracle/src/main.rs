use std::env;
use std::fs::File;
use std::io::BufReader;

use rustysynth::SoundFont;

fn main() {
    let path = env::args().nth(1).expect("usage: oracle <sf2>");
    let file = File::open(&path).expect("cannot open sf2");
    let mut reader = BufReader::new(file);
    let font = SoundFont::new(&mut reader).expect("cannot parse sf2");

    let info = font.get_info();
    println!("version: {}.{}", info.get_version().get_major(), info.get_version().get_minor());
    println!("bank_name: {}", info.get_bank_name());
    println!("presets: {}", font.get_presets().len());
    println!("instruments: {}", font.get_instruments().len());
    println!("sample_headers: {}", font.get_sample_headers().len());
    println!("wave_samples: {}", font.get_wave_data().len());

    let preset0 = font
        .get_presets()
        .iter()
        .find(|p| p.get_bank_number() == 0 && p.get_patch_number() == 0)
        .expect("bank 0 / preset 0 not found");
    println!("preset0: {} regions: {}", preset0.get_name(), preset0.get_regions().len());

    let pr = &preset0.get_regions()[0];
    let inst = &font.get_instruments()[pr.get_instrument_id()];
    let ir = &inst.get_regions()[0];
    println!("instrument: {} regions: {}", inst.get_name(), inst.get_regions().len());
    // Pair reconstruction spot checks (multiplicative Hz, additive int, instrument-only):
    println!(
        "pair[0,0] cutoffHz = {}",
        ir.get_initial_filter_cutoff_frequency() * pr.get_initial_filter_cutoff_frequency()
    );
    println!("pair[0,0] fineTune = {}", ir.get_fine_tune() + pr.get_fine_tune());
    println!("pair[0,0] sampleStart = {}", ir.get_sample_start());
    println!("pair[0,0] rootKey = {}", ir.get_root_key());
}
