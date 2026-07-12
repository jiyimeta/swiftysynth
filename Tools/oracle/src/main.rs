#![recursion_limit = "512"]

use std::env;
use std::fs;
use std::fs::File;
use std::io::BufReader;
use std::process::ExitCode;

use rustysynth::{Instrument, InstrumentRegion, LoopMode, PresetRegion, SampleHeader, SoundFont};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Must match the exact pin in Cargo.toml — recorded into the render-note sidecar.
const RUSTYSYNTH_VERSION: &str = "1.3.6";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("dump-font") if args.len() == 4 => dump_font(&args[2], &args[3]),
        Some("render-note") if args.len() == 5 => render_note(&args[2], &args[3], &args[4]),
        _ => {
            eprintln!("usage: oracle dump-font <sf2> <out.json>");
            eprintln!("       oracle render-note <sf2> <out.wav> <out.json>");
            ExitCode::FAILURE
        }
    }
}

fn load_font(sf2_path: &str) -> SoundFont {
    let file = File::open(sf2_path).expect("cannot open sf2");
    let mut reader = BufReader::new(file);
    SoundFont::new(&mut reader).expect("cannot parse sf2")
}

/// Canonical loop-mode code shared with the Swift tests:
/// 0 = noLoop, 1 = continuous, 2 = loopUntilNoteOff.
fn loop_mode_code(mode: LoopMode) -> i32 {
    match mode {
        LoopMode::NoLoop => 0,
        LoopMode::Continuous => 1,
        LoopMode::LoopUntilNoteOff => 2,
    }
}

fn dump_font(sf2_path: &str, out_path: &str) -> ExitCode {
    let font = load_font(sf2_path);

    // smpl SHA-256 over the little-endian byte serialization of the i16 samples.
    let wave = font.get_wave_data();
    let mut hasher = Sha256::new();
    for s in wave {
        hasher.update(s.to_le_bytes());
    }
    let smpl_sha = hex::encode(hasher.finalize());

    let info = font.get_info();
    let presets = font.get_presets();
    let instruments = font.get_instruments();
    let sample_headers = font.get_sample_headers();

    let preset0 = presets
        .iter()
        .find(|p| p.get_bank_number() == 0 && p.get_patch_number() == 0)
        .expect("bank 0 / preset 0 not found");

    let presets_json: Vec<Value> = presets
        .iter()
        .map(|p| json!({ "bank": p.get_bank_number(), "patch": p.get_patch_number(), "name": p.get_name() }))
        .collect();

    let sample_headers_json: Vec<Value> = sample_headers
        .iter()
        .map(sample_header_json)
        .collect();

    let mut referenced: Vec<usize> = preset0
        .get_regions()
        .iter()
        .map(|r| r.get_instrument_id())
        .collect();
    referenced.sort_unstable();
    referenced.dedup();

    let instruments_json: Vec<Value> = referenced
        .iter()
        .map(|&idx| instrument_json(idx, &instruments[idx], sample_headers))
        .collect();

    let preset_regions_json: Vec<Value> = preset0
        .get_regions()
        .iter()
        .map(|pr| preset_region_json(pr, instruments))
        .collect();

    let mut pairs_json: Vec<Value> = Vec::new();
    for (pi, pr) in preset0.get_regions().iter().enumerate() {
        let inst = &instruments[pr.get_instrument_id()];
        for (ii, ir) in inst.get_regions().iter().enumerate() {
            pairs_json.push(pair_json(pi, pr, ii, ir));
        }
    }

    let dump = json!({
        "version": { "major": info.get_version().get_major(), "minor": info.get_version().get_minor() },
        "romVersion": { "major": info.get_rom_version().get_major(), "minor": info.get_rom_version().get_minor() },
        "info": {
            "targetSoundEngine": info.get_target_sound_engine(),
            "bankName": info.get_bank_name(),
            "romName": info.get_rom_name(),
            "creationDate": info.get_creation_date(),
            "author": info.get_author(),
            "targetProduct": info.get_target_product(),
            "copyright": info.get_copyright(),
            "comments": info.get_comments(),
            "tools": info.get_tools(),
        },
        "counts": {
            "presets": presets.len(),
            "instruments": instruments.len(),
            "sampleHeaders": sample_headers.len(),
        },
        "smpl": { "sampleCount": wave.len(), "sha256": smpl_sha },
        "presets": presets_json,
        "sampleHeaders": sample_headers_json,
        "bank0Preset0": {
            "name": preset0.get_name(),
            "library": preset0.get_library(),
            "genre": preset0.get_genre(),
            "morphology": preset0.get_morphology(),
            "presetRegions": preset_regions_json,
            "instruments": instruments_json,
            "pairs": pairs_json,
        },
    });

    fs::write(out_path, serde_json::to_string(&dump).unwrap()).expect("cannot write json");
    println!("wrote {out_path}");
    ExitCode::SUCCESS
}

fn sample_header_json(h: &SampleHeader) -> Value {
    json!({
        "name": h.get_name(),
        "start": h.get_start(),
        "end": h.get_end(),
        "startLoop": h.get_start_loop(),
        "endLoop": h.get_end_loop(),
        "sampleRate": h.get_sample_rate(),
        "originalPitch": h.get_original_pitch(),
        "pitchCorrection": h.get_pitch_correction(),
        "link": h.get_link(),
        "sampleType": h.get_sample_type(),
    })
}

fn instrument_json(index: usize, inst: &Instrument, sample_headers: &[SampleHeader]) -> Value {
    let regions: Vec<Value> = inst
        .get_regions()
        .iter()
        .map(|ir| instrument_region_json(ir, sample_headers))
        .collect();
    json!({ "index": index, "name": inst.get_name(), "regions": regions })
}

fn preset_region_json(pr: &PresetRegion, instruments: &[Instrument]) -> Value {
    json!({
        "instrumentIndex": pr.get_instrument_id(),
        "instrumentName": instruments[pr.get_instrument_id()].get_name(),
        "keyRangeStart": pr.get_key_range_start(),
        "keyRangeEnd": pr.get_key_range_end(),
        "velocityRangeStart": pr.get_velocity_range_start(),
        "velocityRangeEnd": pr.get_velocity_range_end(),
        "modulationLfoToPitch": pr.get_modulation_lfo_to_pitch(),
        "vibratoLfoToPitch": pr.get_vibrato_lfo_to_pitch(),
        "modulationEnvelopeToPitch": pr.get_modulation_envelope_to_pitch(),
        "modulationLfoToFilterCutoffFrequency": pr.get_modulation_lfo_to_filter_cutoff_frequency(),
        "modulationEnvelopeToFilterCutoffFrequency": pr.get_modulation_envelope_to_filter_cutoff_frequency(),
        "keyNumberToModulationEnvelopeHold": pr.get_key_number_to_modulation_envelope_hold(),
        "keyNumberToModulationEnvelopeDecay": pr.get_key_number_to_modulation_envelope_decay(),
        "keyNumberToVolumeEnvelopeHold": pr.get_key_number_to_volume_envelope_hold(),
        "keyNumberToVolumeEnvelopeDecay": pr.get_key_number_to_volume_envelope_decay(),
        "coarseTune": pr.get_coarse_tune(),
        "fineTune": pr.get_fine_tune(),
        "scaleTuning": pr.get_scale_tuning(),
        "initialFilterCutoffFrequency": pr.get_initial_filter_cutoff_frequency() as f64,
        "initialFilterQ": pr.get_initial_filter_q() as f64,
        "modulationLfoToVolume": pr.get_modulation_lfo_to_volume() as f64,
        "chorusEffectsSend": pr.get_chorus_effects_send() as f64,
        "reverbEffectsSend": pr.get_reverb_effects_send() as f64,
        "pan": pr.get_pan() as f64,
        "delayModulationLfo": pr.get_delay_modulation_lfo() as f64,
        "frequencyModulationLfo": pr.get_frequency_modulation_lfo() as f64,
        "delayVibratoLfo": pr.get_delay_vibrato_lfo() as f64,
        "frequencyVibratoLfo": pr.get_frequency_vibrato_lfo() as f64,
        "delayModulationEnvelope": pr.get_delay_modulation_envelope() as f64,
        "attackModulationEnvelope": pr.get_attack_modulation_envelope() as f64,
        "holdModulationEnvelope": pr.get_hold_modulation_envelope() as f64,
        "decayModulationEnvelope": pr.get_decay_modulation_envelope() as f64,
        "sustainModulationEnvelope": pr.get_sustain_modulation_envelope() as f64,
        "releaseModulationEnvelope": pr.get_release_modulation_envelope() as f64,
        "delayVolumeEnvelope": pr.get_delay_volume_envelope() as f64,
        "attackVolumeEnvelope": pr.get_attack_volume_envelope() as f64,
        "holdVolumeEnvelope": pr.get_hold_volume_envelope() as f64,
        "decayVolumeEnvelope": pr.get_decay_volume_envelope() as f64,
        "sustainVolumeEnvelope": pr.get_sustain_volume_envelope() as f64,
        "releaseVolumeEnvelope": pr.get_release_volume_envelope() as f64,
        "initialAttenuation": pr.get_initial_attenuation() as f64,
    })
}

fn instrument_region_json(ir: &InstrumentRegion, sample_headers: &[SampleHeader]) -> Value {
    json!({
        "sampleIndex": ir.get_sample_id(),
        "sampleName": sample_headers[ir.get_sample_id()].get_name(),
        "sampleStart": ir.get_sample_start(),
        "sampleEnd": ir.get_sample_end(),
        "sampleStartLoop": ir.get_sample_start_loop(),
        "sampleEndLoop": ir.get_sample_end_loop(),
        "startAddressOffset": ir.get_start_address_offset(),
        "endAddressOffset": ir.get_end_address_offset(),
        "startLoopAddressOffset": ir.get_start_loop_address_offset(),
        "endLoopAddressOffset": ir.get_end_loop_address_offset(),
        "sampleModes": loop_mode_code(ir.get_sample_modes()),
        "rootKey": ir.get_root_key(),
        "exclusiveClass": ir.get_exclusive_class(),
        "keyRangeStart": ir.get_key_range_start(),
        "keyRangeEnd": ir.get_key_range_end(),
        "velocityRangeStart": ir.get_velocity_range_start(),
        "velocityRangeEnd": ir.get_velocity_range_end(),
        "modulationLfoToPitch": ir.get_modulation_lfo_to_pitch(),
        "vibratoLfoToPitch": ir.get_vibrato_lfo_to_pitch(),
        "modulationEnvelopeToPitch": ir.get_modulation_envelope_to_pitch(),
        "modulationLfoToFilterCutoffFrequency": ir.get_modulation_lfo_to_filter_cutoff_frequency(),
        "modulationEnvelopeToFilterCutoffFrequency": ir.get_modulation_envelope_to_filter_cutoff_frequency(),
        "keyNumberToModulationEnvelopeHold": ir.get_key_number_to_modulation_envelope_hold(),
        "keyNumberToModulationEnvelopeDecay": ir.get_key_number_to_modulation_envelope_decay(),
        "keyNumberToVolumeEnvelopeHold": ir.get_key_number_to_volume_envelope_hold(),
        "keyNumberToVolumeEnvelopeDecay": ir.get_key_number_to_volume_envelope_decay(),
        "coarseTune": ir.get_coarse_tune(),
        "fineTune": ir.get_fine_tune(),
        "scaleTuning": ir.get_scale_tuning(),
        "initialFilterCutoffFrequency": ir.get_initial_filter_cutoff_frequency() as f64,
        "initialFilterQ": ir.get_initial_filter_q() as f64,
        "modulationLfoToVolume": ir.get_modulation_lfo_to_volume() as f64,
        "chorusEffectsSend": ir.get_chorus_effects_send() as f64,
        "reverbEffectsSend": ir.get_reverb_effects_send() as f64,
        "pan": ir.get_pan() as f64,
        "delayModulationLfo": ir.get_delay_modulation_lfo() as f64,
        "frequencyModulationLfo": ir.get_frequency_modulation_lfo() as f64,
        "delayVibratoLfo": ir.get_delay_vibrato_lfo() as f64,
        "frequencyVibratoLfo": ir.get_frequency_vibrato_lfo() as f64,
        "delayModulationEnvelope": ir.get_delay_modulation_envelope() as f64,
        "attackModulationEnvelope": ir.get_attack_modulation_envelope() as f64,
        "holdModulationEnvelope": ir.get_hold_modulation_envelope() as f64,
        "decayModulationEnvelope": ir.get_decay_modulation_envelope() as f64,
        "sustainModulationEnvelope": ir.get_sustain_modulation_envelope() as f64,
        "releaseModulationEnvelope": ir.get_release_modulation_envelope() as f64,
        "delayVolumeEnvelope": ir.get_delay_volume_envelope() as f64,
        "attackVolumeEnvelope": ir.get_attack_volume_envelope() as f64,
        "holdVolumeEnvelope": ir.get_hold_volume_envelope() as f64,
        "decayVolumeEnvelope": ir.get_decay_volume_envelope() as f64,
        "sustainVolumeEnvelope": ir.get_sustain_volume_envelope() as f64,
        "releaseVolumeEnvelope": ir.get_release_volume_envelope() as f64,
        "initialAttenuation": ir.get_initial_attenuation() as f64,
    })
}

/// RegionPair reconstruction from public getters — see the rules table in the plan (Task 3).
fn pair_json(pi: usize, pr: &PresetRegion, ii: usize, ir: &InstrumentRegion) -> Value {
    json!({
        "presetRegionIndex": pi,
        "instrumentRegionIndex": ii,
        // instrument-only (canonical RegionPair ignores the preset side for these)
        "sampleStart": ir.get_sample_start(),
        "sampleEnd": ir.get_sample_end(),
        "sampleStartLoop": ir.get_sample_start_loop(),
        "sampleEndLoop": ir.get_sample_end_loop(),
        "sampleModes": loop_mode_code(ir.get_sample_modes()),
        "rootKey": ir.get_root_key(),
        "exclusiveClass": ir.get_exclusive_class(),
        // additive ints
        "modulationLfoToPitch": ir.get_modulation_lfo_to_pitch() + pr.get_modulation_lfo_to_pitch(),
        "vibratoLfoToPitch": ir.get_vibrato_lfo_to_pitch() + pr.get_vibrato_lfo_to_pitch(),
        "modulationEnvelopeToPitch": ir.get_modulation_envelope_to_pitch() + pr.get_modulation_envelope_to_pitch(),
        "modulationLfoToFilterCutoffFrequency": ir.get_modulation_lfo_to_filter_cutoff_frequency() + pr.get_modulation_lfo_to_filter_cutoff_frequency(),
        "modulationEnvelopeToFilterCutoffFrequency": ir.get_modulation_envelope_to_filter_cutoff_frequency() + pr.get_modulation_envelope_to_filter_cutoff_frequency(),
        "keyNumberToModulationEnvelopeHold": ir.get_key_number_to_modulation_envelope_hold() + pr.get_key_number_to_modulation_envelope_hold(),
        "keyNumberToModulationEnvelopeDecay": ir.get_key_number_to_modulation_envelope_decay() + pr.get_key_number_to_modulation_envelope_decay(),
        "keyNumberToVolumeEnvelopeHold": ir.get_key_number_to_volume_envelope_hold() + pr.get_key_number_to_volume_envelope_hold(),
        "keyNumberToVolumeEnvelopeDecay": ir.get_key_number_to_volume_envelope_decay() + pr.get_key_number_to_volume_envelope_decay(),
        "coarseTune": ir.get_coarse_tune() + pr.get_coarse_tune(),
        "fineTune": ir.get_fine_tune() + pr.get_fine_tune(),
        "scaleTuning": ir.get_scale_tuning() + pr.get_scale_tuning(),
        // additive floats (dB / percent)
        "modulationLfoToVolume": (ir.get_modulation_lfo_to_volume() + pr.get_modulation_lfo_to_volume()) as f64,
        "chorusEffectsSend": (ir.get_chorus_effects_send() + pr.get_chorus_effects_send()) as f64,
        "reverbEffectsSend": (ir.get_reverb_effects_send() + pr.get_reverb_effects_send()) as f64,
        "pan": (ir.get_pan() + pr.get_pan()) as f64,
        "initialFilterQ": (ir.get_initial_filter_q() + pr.get_initial_filter_q()) as f64,
        "sustainModulationEnvelope": (ir.get_sustain_modulation_envelope() + pr.get_sustain_modulation_envelope()) as f64,
        "sustainVolumeEnvelope": (ir.get_sustain_volume_envelope() + pr.get_sustain_volume_envelope()) as f64,
        "initialAttenuation": (ir.get_initial_attenuation() + pr.get_initial_attenuation()) as f64,
        // multiplicative floats (Hz / seconds): instrument absolute × preset factor
        "initialFilterCutoffFrequency": (ir.get_initial_filter_cutoff_frequency() * pr.get_initial_filter_cutoff_frequency()) as f64,
        "delayModulationLfo": (ir.get_delay_modulation_lfo() * pr.get_delay_modulation_lfo()) as f64,
        "frequencyModulationLfo": (ir.get_frequency_modulation_lfo() * pr.get_frequency_modulation_lfo()) as f64,
        "delayVibratoLfo": (ir.get_delay_vibrato_lfo() * pr.get_delay_vibrato_lfo()) as f64,
        "frequencyVibratoLfo": (ir.get_frequency_vibrato_lfo() * pr.get_frequency_vibrato_lfo()) as f64,
        "delayModulationEnvelope": (ir.get_delay_modulation_envelope() * pr.get_delay_modulation_envelope()) as f64,
        "attackModulationEnvelope": (ir.get_attack_modulation_envelope() * pr.get_attack_modulation_envelope()) as f64,
        "holdModulationEnvelope": (ir.get_hold_modulation_envelope() * pr.get_hold_modulation_envelope()) as f64,
        "decayModulationEnvelope": (ir.get_decay_modulation_envelope() * pr.get_decay_modulation_envelope()) as f64,
        "releaseModulationEnvelope": (ir.get_release_modulation_envelope() * pr.get_release_modulation_envelope()) as f64,
        "delayVolumeEnvelope": (ir.get_delay_volume_envelope() * pr.get_delay_volume_envelope()) as f64,
        "attackVolumeEnvelope": (ir.get_attack_volume_envelope() * pr.get_attack_volume_envelope()) as f64,
        "holdVolumeEnvelope": (ir.get_hold_volume_envelope() * pr.get_hold_volume_envelope()) as f64,
        "decayVolumeEnvelope": (ir.get_decay_volume_envelope() * pr.get_decay_volume_envelope()) as f64,
        "releaseVolumeEnvelope": (ir.get_release_volume_envelope() * pr.get_release_volume_envelope()) as f64,
    })
}

fn render_note(sf2_path: &str, wav_path: &str, json_path: &str) -> ExitCode {
    use std::sync::Arc;

    use rustysynth::{Synthesizer, SynthesizerSettings};

    let font_bytes = fs::read(sf2_path).expect("cannot read sf2");
    let font_sha = hex::encode(Sha256::digest(&font_bytes));
    let mut cursor = std::io::Cursor::new(font_bytes);
    let font = Arc::new(SoundFont::new(&mut cursor).expect("cannot parse sf2"));

    // Equivalence-critical settings: block 64, dry render (the spike has no effects),
    // fixed pool 8, master volume 0.5.
    let mut settings = SynthesizerSettings::new(44_100);
    settings.block_size = 64;
    settings.maximum_polyphony = 8;
    settings.enable_reverb_and_chorus = false;
    let mut synth = Synthesizer::new(&font, &settings).expect("cannot create synthesizer");
    synth.set_master_volume(0.5);

    const NOTE_OFF_FRAME: usize = 88_200; // 2.0 s
    const TOTAL_FRAMES: usize = 220_500; // 5.0 s
    let mut left = vec![0.0f32; TOTAL_FRAMES];
    let mut right = vec![0.0f32; TOTAL_FRAMES];

    // Two-chunk render matching the Swift G2 test EXACTLY. 88200 is not a multiple of the
    // 64-frame internal block, so the note-off lands mid-carry; because both sides render
    // the same two chunk sizes, the release starts at the same internal block boundary in
    // both implementations. Do NOT render 220500 frames in one call with a scheduled event.
    synth.note_on(0, 60, 100);
    synth.render(&mut left[..NOTE_OFF_FRAME], &mut right[..NOTE_OFF_FRAME]);
    synth.note_off(0, 60);
    synth.render(&mut left[NOTE_OFF_FRAME..], &mut right[NOTE_OFF_FRAME..]);

    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44_100,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(wav_path, spec).expect("cannot create wav");
    for i in 0..TOTAL_FRAMES {
        writer.write_sample(left[i]).unwrap();
        writer.write_sample(right[i]).unwrap();
    }
    writer.finalize().unwrap();

    let peak = left
        .iter()
        .chain(right.iter())
        .fold(0.0f32, |m, s| m.max(s.abs()));

    let sidecar = json!({
        "bank": 0,
        "patch": 0,
        "key": 60,
        "velocity": 100,
        "sampleRate": 44_100,
        "noteOnFrame": 0,
        "noteOffFrame": NOTE_OFF_FRAME,
        "totalFrames": TOTAL_FRAMES,
        "masterVolume": 0.5,
        "blockSize": 64,
        "maximumPolyphony": 8,
        "enableReverbAndChorus": false,
        "rustysynthVersion": RUSTYSYNTH_VERSION,
        "soundFontSha256": font_sha,
    });
    fs::write(json_path, serde_json::to_string_pretty(&sidecar).unwrap()).expect("cannot write sidecar");
    println!("wrote {wav_path} (peak {peak}) and {json_path}");
    ExitCode::SUCCESS
}
