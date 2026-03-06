# Night Mode Validation Procedure

This document describes the validation procedure for LifeOS Night Mode, ensuring it effectively reduces eye strain during extended work sessions (3+ hours).

## Overview

Night Mode in LifeOS reduces blue light emission and applies a warm color temperature to the display. This validation procedure ensures the feature meets its ergonomic goals.

### What Night Mode Does

- **Blue Light Reduction**: Decreases blue light wavelengths (450-495nm) by 50-80%
- **Color Temperature**: Shifts from default 6500K to 2700K-3400K (warm)
- **Adaptive Intensity**: Can automatically adjust based on time of day
- **Custom Schedules**: User-defined activation times

### Validation Goals

The validation ensures Night Mode:
1. Maintains eye comfort ≥ 7/10 after 3+ hours of use
2. Does not cause headaches or eye strain
3. Preserves sufficient color accuracy for work tasks
4. Does not negatively impact sleep quality
5. Maintains or improves productivity

## Prerequisites

Before starting validation:

- [ ] Night Mode feature implemented and functional
- [ ] Validation script available at `scripts/validate-night-mode.sh`
- [ ] At least 3 hours of uninterrupted work time
- [ ] Appropriate room lighting (not too bright/dark)
- [ ] Screen brightness at comfortable level

## Validation Procedure

### Step 1: Enable Night Mode

```bash
# Enable Night Mode manually
life focus night

# Or enable with automatic scheduling
life focus night --schedule sunset-to-sunrise

# Or enable with custom intensity
life focus night --intensity 70  # 70% blue light reduction
```

### Step 2: Start Validation Session

```bash
./scripts/validate-night-mode.sh start
```

This will:
- Record baseline eye comfort level
- Note session start time
- Create session tracking file

### Step 3: Work Normally

Continue your regular work activities for at least 3 hours. Tasks should include:
- Reading text (documents, code, web)
- Viewing images or videos
- Using various applications

### Step 4: Mid-Session Checkpoints

Every 30-60 minutes, run:

```bash
./scripts/validate-night-mode.sh check
```

This records:
- Current eye comfort level (1-10)
- Any eye strain or headache
- Screen readability assessment
- Color distinguishability

### Step 5: End Session

After 3+ hours:

```bash
./scripts/validate-night-mode.sh end
```

This collects:
- Final comfort assessment
- Sleep quality (next day)
- Productivity assessment
- Color accuracy evaluation
- Overall satisfaction

### Step 6: Generate Report

```bash
./scripts/validate-night-mode.sh report
```

## Pass/Fail Criteria

### Pass Criteria (ALL must be met)

| Criterion | Requirement |
|-----------|-------------|
| Final eye comfort | ≥ 7/10 |
| Headache during session | No |
| Significant eye strain | No |
| Sleep quality | ≥ 6/10 (if applicable) |
| Would use again | Yes |

### Additional Quality Metrics

These don't cause failure but should be noted:

| Metric | Target |
|--------|--------|
| Comfort change | ≥ 0 (no degradation) |
| Productivity | Maintained or improved |
| Color accuracy | Acceptable for work tasks |

## Human-in-the-Loop Checklist

Since eye strain cannot be automatically measured, this validation requires honest self-assessment:

```
╔══════════════════════════════════════════════════════════════════════╗
║          NIGHT MODE VALIDATION CHECKLIST (3+ Hour Session)           ║
╚══════════════════════════════════════════════════════════════════════╝

═══ PRE-SESSION CHECKLIST ═══
□ Night Mode enabled (life focus night or auto)
□ Room lighting appropriate (not too bright/dark)
□ Screen brightness at comfortable level
□ Baseline eye comfort recorded
□ Start time noted

═══ MID-SESSION CHECKLIST (Every 30-60 min) ═══
□ Eye comfort level (1-10): ____
□ Any eye strain noticed? (Y/N): ____
□ Any headache? (Y/N): ____
□ Screen readability acceptable? (Y/N): ____
□ Colors distinguishable? (Y/N): ____
□ Time of checkpoint: ____

═══ POST-SESSION CHECKLIST (After 3+ hours) ═══
□ Total session duration: ____ hours
□ Final eye comfort level (1-10): ____
□ Eye strain during session? (Y/N): ____
□ Headache during session? (Y/N): ____
□ Dry eyes? (Y/N): ____
□ Difficulty focusing? (Y/N): ____
□ Sleep quality same night (1-10): ____
□ Work productivity maintained? (Y/N): ____
□ Would use Night Mode again? (Y/N): ____

═══ COLOR ACCURACY ASSESSMENT ═══
□ Code syntax highlighting readable? (Y/N): ____
□ Images/photos acceptable? (Y/N): ____
□ UI elements distinguishable? (Y/N): ____
□ Text contrast sufficient? (Y/N): ____

═══ VALIDATION RESULT ═══
Pass Criteria (all must be met):
  ✓ Final eye comfort ≥ 7/10
  ✓ No headache reported
  ✓ No significant eye strain
  ✓ Sleep quality ≥ 6/10
  ✓ Would use again = Yes

Result: PASS / FAIL

═══ NOTES ═══
_____________________________________________
_____________________________________________
_____________________________________________

Validator: ________________  Date: ________________
```

## Multiple Validators

For robust validation, gather data from multiple users:

| Validator | Date | Duration | Comfort Δ | Result |
|-----------|------|----------|-----------|--------|
| Validator 1 | YYYY-MM-DD | Xh Xm | +X/-X | PASS/FAIL |
| Validator 2 | YYYY-MM-DD | Xh Xm | +X/-X | PASS/FAIL |
| Validator 3 | YYYY-MM-DD | Xh Xm | +X/-X | PASS/FAIL |

**Minimum for validation**: 3 validators with PASS result

## Technical Implementation Notes

### Color Temperature Settings

| Mode | Temperature | Blue Reduction | Use Case |
|------|-------------|----------------|----------|
| Mild | 4500K | ~30% | Slight reduction |
| Standard | 3400K | ~50% | Default for evening |
| Strong | 2700K | ~70% | Late night |
| Custom | 2700K-6500K | Variable | User preference |

### Display Technology Considerations

- **LCD**: Blue light filter is effective
- **OLED**: More effective due to pixel-level control
- **LED Backlight**: May need stronger settings

### Integration Points

Night Mode integrates with:
- `life focus night` - CLI command
- `lifeosd` daemon - Background scheduling
- GNOME Settings - System integration
- D-Bus API - External control

## Troubleshooting

### Colors Too Distorted

If colors are unacceptable:
```bash
# Reduce intensity
life focus night --intensity 50

# Use milder temperature
life focus night --temperature 4500
```

### Still Experiencing Eye Strain

If eye strain persists:
1. Check room lighting - too dark can cause strain
2. Adjust screen brightness
3. Consider the 20-20-20 rule (every 20 min, look 20 feet away for 20 sec)
4. Verify the display's blue light filter is working

### Sleep Issues

If sleep is negatively affected:
1. Enable Night Mode earlier in the evening
2. Increase intensity progressively toward bedtime
3. Combine with reducing screen time before bed

## Validation Report Template

```markdown
# Night Mode Validation Report

**Session ID:** session-YYYYMMDD-HHMMSS  
**Generated:** YYYY-MM-DDTHH:MM:SS  

## Session Overview

| Metric | Value |
|--------|-------|
| Start Time | [timestamp] |
| End Time | [timestamp] |
| Duration | Xh Xm |
| Checkpoints | N |
| Result | **PASS/FAIL** |

## Comfort Scores

| Measurement | Score |
|-------------|-------|
| Baseline (start) | X/10 |
| Final (end) | X/10 |
| Change | +/-X |

## Validation Criteria

| Criterion | Required | Actual | Status |
|-----------|----------|--------|--------|
| Final comfort | ≥ 7/10 | X/10 | ✓/✗ |
| No headache | Yes | No | ✓ |
| No eye strain | Yes | No | ✓ |
| Sleep quality | ≥ 6/10 | X/10 | ✓/✗ |
| Would use again | Yes | Yes | ✓ |

## Conclusion

[Summary of validation results and recommendations]
```

## See Also

- [Design Tokens](design-tokens.md) - Color system definitions
- [Theme System](THEMES.md) - LifeOS theme documentation
- [Focus Modes](user-guide.md#focus-modes) - Focus mode documentation
- [WCAG 2.2 Guidelines](https://www.w3.org/TR/WCAG22/) - Accessibility standards
