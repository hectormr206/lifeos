use std::f32::consts::PI;

const HIGH_PASS_CUTOFF_HZ: f32 = 140.0;
const NOISE_GATE_FLOOR: f64 = 55.0;
const NOISE_GATE_MULTIPLIER: f64 = 1.25;
const NOISE_GATE_SOFT_ATTENUATION: f32 = 0.24;
const NOISE_GATE_TRANSITION_ATTENUATION: f32 = 0.62;
const NOISE_GATE_TRANSITION_MULTIPLIER: f64 = 2.0;
const MIN_ZERO_CROSSING_RATE: f64 = 0.015;
const MIN_DIFF_RMS_RATIO: f64 = 0.20;
const MIN_PEAK_TO_RMS_RATIO: f64 = 1.35;
const MIN_SPEECH_BAND_RATIO: f64 = 0.45;
const BARGE_IN_THRESHOLD_MULTIPLIER: f64 = 1.45;
const BARGE_IN_MIN_ZERO_CROSSING_RATE: f64 = 0.022;
const BARGE_IN_MIN_DIFF_RMS_RATIO: f64 = 0.28;
const BARGE_IN_MIN_PEAK_TO_RMS_RATIO: f64 = 1.55;
const BARGE_IN_MIN_SPEECH_BAND_RATIO: f64 = 0.58;
const LOW_BAND_FREQS_HZ: [f32; 3] = [80.0, 120.0, 180.0];
const SPEECH_BAND_FREQS_HZ: [f32; 5] = [320.0, 640.0, 1000.0, 1600.0, 2400.0];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceActivityProfile {
    Normal,
    BargeIn,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct AudioFilterState {
    prev_input: f32,
    prev_output: f32,
    prev_filtered_sample: f32,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct AudioFrameStats {
    pub rms: f64,
    pub peak: f64,
    pub zero_crossing_rate: f64,
    pub diff_rms_ratio: f64,
    pub speech_band_ratio: f64,
}

pub struct ProcessedAudioFrame {
    pub pcm_le: Vec<u8>,
    pub stats: AudioFrameStats,
}

pub fn preprocess_frame_i16le(
    input_pcm_le: &[u8],
    sample_rate: u32,
    gain_db: f64,
    noise_floor: Option<f64>,
    state: &mut AudioFilterState,
) -> ProcessedAudioFrame {
    let gain_linear = 10f32.powf(gain_db as f32 / 20.0);
    let gate_floor = noise_gate_threshold(noise_floor) as f32;
    let transition_floor =
        (noise_gate_threshold(noise_floor) * NOISE_GATE_TRANSITION_MULTIPLIER) as f32;
    let alpha = high_pass_alpha(sample_rate.max(1));

    let mut pcm_le = Vec::with_capacity(input_pcm_le.len());
    let mut sum_sq = 0f64;
    let mut diff_sum_sq = 0f64;
    let mut count = 0usize;
    let mut zero_crossings = 0usize;
    let mut peak = 0f64;
    let mut previous_sign = 0i8;
    let low_coeffs = goertzel_coefficients(sample_rate, &LOW_BAND_FREQS_HZ);
    let speech_coeffs = goertzel_coefficients(sample_rate, &SPEECH_BAND_FREQS_HZ);
    let mut low_prev = vec![0f32; low_coeffs.len()];
    let mut low_prev2 = vec![0f32; low_coeffs.len()];
    let mut speech_prev = vec![0f32; speech_coeffs.len()];
    let mut speech_prev2 = vec![0f32; speech_coeffs.len()];

    for chunk in input_pcm_le.chunks_exact(2) {
        let raw = i16::from_le_bytes([chunk[0], chunk[1]]) as f32 * gain_linear;
        let filtered = alpha * (state.prev_output + raw - state.prev_input);
        state.prev_input = raw;
        state.prev_output = filtered;

        let mut cleaned = filtered;
        let abs = cleaned.abs();
        if abs < gate_floor {
            cleaned *= NOISE_GATE_SOFT_ATTENUATION;
        } else if abs < transition_floor {
            cleaned *= NOISE_GATE_TRANSITION_ATTENUATION;
        }

        let clipped = cleaned.clamp(-32768.0, 32767.0);
        let sample_i16 = clipped as i16;
        pcm_le.extend_from_slice(&sample_i16.to_le_bytes());
        update_goertzel_bank(clipped, &low_coeffs, &mut low_prev, &mut low_prev2);
        update_goertzel_bank(clipped, &speech_coeffs, &mut speech_prev, &mut speech_prev2);

        let sample = sample_i16 as f64;
        let abs_sample = sample.abs();
        if abs_sample > peak {
            peak = abs_sample;
        }
        sum_sq += sample * sample;

        let diff = clipped - state.prev_filtered_sample;
        diff_sum_sq += (diff as f64) * (diff as f64);
        state.prev_filtered_sample = clipped;

        let sign = if abs_sample < (gate_floor as f64 * 0.25) {
            0
        } else if sample >= 0.0 {
            1
        } else {
            -1
        };
        if sign != 0 && previous_sign != 0 && sign != previous_sign {
            zero_crossings += 1;
        }
        if sign != 0 {
            previous_sign = sign;
        }

        count += 1;
    }

    let rms = if count > 0 {
        (sum_sq / count as f64).sqrt()
    } else {
        0.0
    };
    let diff_rms = if count > 0 {
        (diff_sum_sq / count as f64).sqrt()
    } else {
        0.0
    };
    let low_power = goertzel_power_sum(&low_coeffs, &low_prev, &low_prev2);
    let speech_power = goertzel_power_sum(&speech_coeffs, &speech_prev, &speech_prev2);
    let speech_band_ratio = if speech_power > 0.0 || low_power > 0.0 {
        speech_power / (speech_power + low_power + 1.0)
    } else {
        0.0
    };

    ProcessedAudioFrame {
        pcm_le,
        stats: AudioFrameStats {
            rms,
            peak,
            zero_crossing_rate: if count > 0 {
                zero_crossings as f64 / count as f64
            } else {
                0.0
            },
            diff_rms_ratio: if rms > 0.0 { diff_rms / rms } else { 0.0 },
            speech_band_ratio,
        },
    }
}

pub fn looks_like_voice(stats: &AudioFrameStats, rms_threshold: f64) -> bool {
    looks_like_voice_with_profile(stats, rms_threshold, VoiceActivityProfile::Normal)
}

pub fn looks_like_voice_with_profile(
    stats: &AudioFrameStats,
    rms_threshold: f64,
    profile: VoiceActivityProfile,
) -> bool {
    let (
        threshold_multiplier,
        min_zero_crossing_rate,
        min_diff_rms_ratio,
        min_peak_to_rms_ratio,
        min_speech_band_ratio,
    ) = match profile {
        VoiceActivityProfile::Normal => (
            1.0,
            MIN_ZERO_CROSSING_RATE,
            MIN_DIFF_RMS_RATIO,
            MIN_PEAK_TO_RMS_RATIO,
            MIN_SPEECH_BAND_RATIO,
        ),
        VoiceActivityProfile::BargeIn => (
            BARGE_IN_THRESHOLD_MULTIPLIER,
            BARGE_IN_MIN_ZERO_CROSSING_RATE,
            BARGE_IN_MIN_DIFF_RMS_RATIO,
            BARGE_IN_MIN_PEAK_TO_RMS_RATIO,
            BARGE_IN_MIN_SPEECH_BAND_RATIO,
        ),
    };
    let effective_threshold = rms_threshold * threshold_multiplier;

    if stats.rms < effective_threshold {
        return false;
    }
    if stats.zero_crossing_rate < min_zero_crossing_rate {
        return false;
    }
    if stats.diff_rms_ratio < min_diff_rms_ratio {
        return false;
    }
    if stats.speech_band_ratio < min_speech_band_ratio {
        return false;
    }

    if stats.peak >= effective_threshold * min_peak_to_rms_ratio {
        return true;
    }

    stats.rms >= effective_threshold * 1.2 && stats.diff_rms_ratio >= (min_diff_rms_ratio * 1.15)
}

pub fn noise_gate_threshold(noise_floor: Option<f64>) -> f64 {
    noise_floor
        .map(|floor| (floor * NOISE_GATE_MULTIPLIER).max(NOISE_GATE_FLOOR))
        .unwrap_or(NOISE_GATE_FLOOR)
}

fn high_pass_alpha(sample_rate: u32) -> f32 {
    let dt = 1.0 / sample_rate as f32;
    let rc = 1.0 / (2.0 * PI * HIGH_PASS_CUTOFF_HZ);
    rc / (rc + dt)
}

fn goertzel_coefficients(sample_rate: u32, frequencies_hz: &[f32]) -> Vec<f32> {
    frequencies_hz
        .iter()
        .map(|freq_hz| 2.0 * (2.0 * PI * freq_hz / sample_rate.max(1) as f32).cos())
        .collect()
}

fn update_goertzel_bank(sample: f32, coeffs: &[f32], prev: &mut [f32], prev2: &mut [f32]) {
    for i in 0..coeffs.len() {
        let current = sample + coeffs[i] * prev[i] - prev2[i];
        prev2[i] = prev[i];
        prev[i] = current;
    }
}

fn goertzel_power_sum(coeffs: &[f32], prev: &[f32], prev2: &[f32]) -> f64 {
    coeffs
        .iter()
        .enumerate()
        .map(|(i, coeff)| {
            let power = prev2[i] * prev2[i] + prev[i] * prev[i] - coeff * prev[i] * prev2[i];
            power.max(0.0) as f64
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::{
        looks_like_voice, looks_like_voice_with_profile, preprocess_frame_i16le, AudioFilterState,
        AudioFrameStats, VoiceActivityProfile,
    };
    use std::f32::consts::PI;

    #[test]
    fn low_frequency_hum_is_not_voice_like() {
        let frame = synth_sine(120.0, 0.25, 9000.0);
        let processed = preprocess_frame_i16le(
            &frame,
            16_000,
            0.0,
            Some(90.0),
            &mut AudioFilterState::default(),
        );
        assert!(!looks_like_voice(&processed.stats, 180.0));
    }

    #[test]
    fn speech_like_frame_survives_frontend() {
        let frame = synth_voice_like(0.25);
        let processed = preprocess_frame_i16le(
            &frame,
            16_000,
            4.0,
            Some(80.0),
            &mut AudioFilterState::default(),
        );
        assert!(looks_like_voice(&processed.stats, 170.0));
    }

    #[test]
    fn barge_in_profile_is_stricter_than_normal_voice_profile() {
        let stats = AudioFrameStats {
            rms: 230.0,
            peak: 330.0,
            zero_crossing_rate: 0.018,
            diff_rms_ratio: 0.24,
            speech_band_ratio: 0.61,
        };

        assert!(looks_like_voice_with_profile(
            &stats,
            180.0,
            VoiceActivityProfile::Normal
        ));
        assert!(!looks_like_voice_with_profile(
            &stats,
            180.0,
            VoiceActivityProfile::BargeIn
        ));
    }

    #[test]
    fn speech_band_ratio_separates_voice_from_fan_hum() {
        let hum = preprocess_frame_i16le(
            &synth_sine(120.0, 0.25, 9000.0),
            16_000,
            0.0,
            Some(90.0),
            &mut AudioFilterState::default(),
        );
        let voice = preprocess_frame_i16le(
            &synth_voice_like(0.25),
            16_000,
            4.0,
            Some(80.0),
            &mut AudioFilterState::default(),
        );

        assert!(hum.stats.speech_band_ratio < 0.40);
        assert!(voice.stats.speech_band_ratio > 0.50);
    }

    fn synth_sine(freq_hz: f32, duration_secs: f32, amplitude: f32) -> Vec<u8> {
        let sample_rate = 16_000f32;
        let samples = (sample_rate * duration_secs) as usize;
        let mut out = Vec::with_capacity(samples * 2);
        for n in 0..samples {
            let t = n as f32 / sample_rate;
            let sample = (amplitude * (2.0 * PI * freq_hz * t).sin()).round() as i16;
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }

    fn synth_voice_like(duration_secs: f32) -> Vec<u8> {
        let sample_rate = 16_000f32;
        let samples = (sample_rate * duration_secs) as usize;
        let mut out = Vec::with_capacity(samples * 2);
        for n in 0..samples {
            let t = n as f32 / sample_rate;
            let envelope = if (n / 240) % 2 == 0 { 1.0 } else { 0.35 };
            let sample = envelope
                * (6000.0 * (2.0 * PI * 220.0 * t).sin()
                    + 3200.0 * (2.0 * PI * 880.0 * t).sin()
                    + 1600.0 * (2.0 * PI * 1760.0 * t).sin());
            out.extend_from_slice(&(sample.round() as i16).to_le_bytes());
        }
        out
    }
}
