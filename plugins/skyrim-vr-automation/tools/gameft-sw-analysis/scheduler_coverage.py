"""Scheduler accounting tolerance for gameft-sw's ten-second tail windows."""
import math

WINDOW_MS = 10000.0
TOLERANCE_MS = 10.0
POLICY_ID = "gameft-sw-scheduler-coverage-10ms-20260918"


def coverage_passed(error_ms):
    """Accept finite accounting error within the inclusive absolute bound."""
    if isinstance(error_ms, bool) or not isinstance(error_ms, (int, float)):
        return False
    return abs(error_ms) <= TOLERANCE_MS and math.isfinite(error_ms)
