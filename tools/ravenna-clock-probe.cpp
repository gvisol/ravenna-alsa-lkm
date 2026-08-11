// Read-only diagnostic for a RAVENNA capture stream.
// It compares the driver's PTP-phase-locked Sample Address Counter (SAC)
// against CLOCK_TAI without interacting with ALSA or OnTimeCM.

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>

#include <time.h>

namespace
{
constexpr const char* snapshotPath =
    "/sys/module/MergingRavennaALSA/parameters/capture_timing_snapshot";

uint64_t toNs (const timespec& value)
{
    return static_cast<uint64_t> (value.tv_sec) * 1'000'000'000ULL
         + static_cast<uint64_t> (value.tv_nsec);
}

uint64_t readClockNs (clockid_t clock)
{
    timespec value {};
    if (clock_gettime (clock, &value) != 0)
    {
        std::cerr << "clock_gettime failed: " << std::strerror (errno) << '\n';
        std::exit (2);
    }

    return toNs (value);
}

bool getUnsigned (const std::string& line, const std::string& name, uint64_t& result)
{
    const auto key = name + "=";
    const auto begin = line.find (key);
    if (begin == std::string::npos)
        return false;

    const auto valueBegin = begin + key.size();
    const auto valueEnd = line.find_first_of (" \\n", valueBegin);

    try
    {
        result = std::stoull (line.substr (valueBegin, valueEnd - valueBegin));
        return true;
    }
    catch (...)
    {
        return false;
    }
}

bool getSigned (const std::string& line, const std::string& name, int64_t& result)
{
    const auto key = name + "=";
    const auto begin = line.find (key);
    if (begin == std::string::npos)
        return false;

    const auto valueBegin = begin + key.size();
    const auto valueEnd = line.find_first_of (" \\n", valueBegin);

    try
    {
        result = std::stoll (line.substr (valueBegin, valueEnd - valueBegin));
        return true;
    }
    catch (...)
    {
        return false;
    }
}

struct Snapshot
{
    uint64_t sac = 0;
    uint64_t monotonicTime100us = 0;
    uint64_t estimatedPtpTime100us = 0;
    int64_t ptpToMonotonicOffset100us = 0;
    uint64_t ticBasePeriodPs = 0;
    uint64_t ticCurrentPeriodPs = 0;
    uint64_t ptpLockPending = 0;
    uint64_t ticLockPending = 0;
    uint64_t systemTaiTimeline = 0;
    uint64_t lastSyncRxHardwareTimestampNs = 0;
    uint64_t lastSyncRxMonotonicTimestampNs = 0;
    uint64_t lastSyncOriginTimestampNs = 0;
    uint64_t sampleRate = 0;
};

bool readSnapshot (Snapshot& snapshot)
{
    std::ifstream input (snapshotPath);
    std::string line;
    std::getline (input, line);

    uint64_t valid = 0;
    return getUnsigned (line, "valid", valid)
        && valid == 1
        && getUnsigned (line, "sac_start", snapshot.sac)
        && getUnsigned (line, "monotonic_time_100us", snapshot.monotonicTime100us)
        && getUnsigned (line, "estimated_ptp_time_100us", snapshot.estimatedPtpTime100us)
        && getSigned (line, "ptp_to_monotonic_offset_100us",
                      snapshot.ptpToMonotonicOffset100us)
        && getUnsigned (line, "tic_base_period_ps", snapshot.ticBasePeriodPs)
        && getUnsigned (line, "tic_current_period_ps", snapshot.ticCurrentPeriodPs)
        && getUnsigned (line, "ptp_lock_pending", snapshot.ptpLockPending)
        && getUnsigned (line, "tic_lock_pending", snapshot.ticLockPending)
        && getUnsigned (line, "system_tai_timeline", snapshot.systemTaiTimeline)
        && getUnsigned (line, "last_sync_rx_hardware_timestamp_ns",
                         snapshot.lastSyncRxHardwareTimestampNs)
        && getUnsigned (line, "last_sync_rx_monotonic_timestamp_ns",
                         snapshot.lastSyncRxMonotonicTimestampNs)
        && getUnsigned (line, "last_sync_origin_timestamp_ns",
                         snapshot.lastSyncOriginTimestampNs)
        && getUnsigned (line, "sample_rate", snapshot.sampleRate);
}
}

int main (int argc, char* argv[])
{
    const int samples = argc > 1 ? std::max (2, std::atoi (argv[1])) : 61;
    const int intervalMs = argc > 2 ? std::max (1, std::atoi (argv[2])) : 1000;

    bool haveReference = false;
    uint64_t referenceSac = 0;
    uint64_t referenceTaiNs = 0;
    uint64_t referencePtpNs = 0;
    uint64_t previousSac = 0;

    for (int index = 0; index < samples; ++index)
    {
        Snapshot snapshot;
        const auto monotonicBeforeNs = readClockNs (CLOCK_MONOTONIC);
        const auto taiBeforeNs = readClockNs (CLOCK_TAI);
        const auto valid = readSnapshot (snapshot);
        const auto monotonicAfterNs = readClockNs (CLOCK_MONOTONIC);
        const auto taiAfterNs = readClockNs (CLOCK_TAI);

        if (! valid)
        {
            std::cout << "RAVENNA_CLOCK sample=" << index << " valid=0\n";
        }
        else
        {
            const auto monotonicReadNs = (monotonicBeforeNs + monotonicAfterNs) / 2;
            const auto taiReadNs = (taiBeforeNs + taiAfterNs) / 2;
            const auto ticMonotonicNs = snapshot.monotonicTime100us * 100'000ULL;
            const auto ticTaiNs = static_cast<int64_t> (taiReadNs)
                                - (static_cast<int64_t> (monotonicReadNs)
                                   - static_cast<int64_t> (ticMonotonicNs));
            const auto driverPtpNs = snapshot.estimatedPtpTime100us * 100'000ULL;
            const auto snapshotAgeUs = (static_cast<int64_t> (monotonicReadNs)
                                      - static_cast<int64_t> (ticMonotonicNs)) / 1'000;
            const auto driverPtpMinusTaiUs =
                (static_cast<int64_t> (driverPtpNs) - ticTaiNs) / 1'000;
            const auto lastSyncSoftwareTaiNs =
                static_cast<int64_t> (taiReadNs)
                - (static_cast<int64_t> (monotonicReadNs)
                   - static_cast<int64_t> (snapshot.lastSyncRxMonotonicTimestampNs));

            std::cout << "RAVENNA_CLOCK sample=" << index
                      << " valid=1"
                      << " sac=" << snapshot.sac
                      << " tic_tai_ns=" << ticTaiNs
                      << " driver_ptp_ns=" << driverPtpNs
                      << " driver_ptp_minus_tai_us=" << driverPtpMinusTaiUs
                      << " snapshot_age_us=" << snapshotAgeUs
                      << " sample_rate=" << snapshot.sampleRate
                      << " ptp_lock_pending=" << snapshot.ptpLockPending
                      << " tic_lock_pending=" << snapshot.ticLockPending
                      << " system_tai_timeline=" << snapshot.systemTaiTimeline
                      << " last_sync_rx_hardware_timestamp_ns="
                      << snapshot.lastSyncRxHardwareTimestampNs
                      << " last_sync_rx_software_tai_ns=" << lastSyncSoftwareTaiNs;

            if (snapshot.lastSyncOriginTimestampNs != 0U)
            {
                const auto softwareMinusOriginUs =
                    (lastSyncSoftwareTaiNs
                     - static_cast<int64_t> (snapshot.lastSyncOriginTimestampNs)) / 1'000;
                std::cout << " last_sync_software_minus_origin_us="
                          << softwareMinusOriginUs;
            }

            if (snapshot.lastSyncRxHardwareTimestampNs != 0U)
            {
                const auto hardwareMinusTaiUs =
                    (static_cast<int64_t> (snapshot.lastSyncRxHardwareTimestampNs)
                     - lastSyncSoftwareTaiNs) / 1'000;
                std::cout << " last_sync_hw_minus_software_tai_us="
                          << hardwareMinusTaiUs;
                if (snapshot.lastSyncOriginTimestampNs != 0U)
                {
                    const auto hardwareMinusOriginUs =
                        (static_cast<int64_t> (snapshot.lastSyncRxHardwareTimestampNs)
                         - static_cast<int64_t> (snapshot.lastSyncOriginTimestampNs)) / 1'000;
                    std::cout << " last_sync_hw_minus_origin_us="
                              << hardwareMinusOriginUs;
                }
            }

            std::cout
                      << " tic_base_period_ps=" << snapshot.ticBasePeriodPs
                      << " tic_current_period_ps=" << snapshot.ticCurrentPeriodPs;

            if (haveReference && snapshot.sac != referenceSac && ticTaiNs > static_cast<int64_t> (referenceTaiNs))
            {
                const auto elapsedNs = static_cast<uint64_t> (ticTaiNs) - referenceTaiNs;
                const auto elapsedSamples = snapshot.sac - referenceSac;
                const auto observedRate = static_cast<long double> (elapsedSamples) * 1'000'000'000.0L
                                        / static_cast<long double> (elapsedNs);
                const auto ppm = (observedRate / static_cast<long double> (snapshot.sampleRate) - 1.0L) * 1'000'000.0L;
                std::cout << " observed_rate_hz=" << static_cast<double> (observedRate)
                          << " rate_error_ppm=" << static_cast<double> (ppm);

                if (driverPtpNs > referencePtpNs)
                {
                    const auto elapsedDriverPtpNs = driverPtpNs - referencePtpNs;
                    const auto observedPtpRate =
                        static_cast<long double> (elapsedSamples) * 1'000'000'000.0L /
                        static_cast<long double> (elapsedDriverPtpNs);
                    const auto ptpPpm =
                        (observedPtpRate / static_cast<long double> (snapshot.sampleRate) - 1.0L) *
                        1'000'000.0L;
                    std::cout << " observed_rate_vs_driver_ptp_hz="
                              << static_cast<double> (observedPtpRate)
                              << " driver_ptp_rate_error_ppm=" << static_cast<double> (ptpPpm);
                }
            }

            std::cout << '\n';

            if (! haveReference || snapshot.sac != previousSac)
            {
                if (! haveReference)
                {
                    referenceSac = snapshot.sac;
                    referenceTaiNs = static_cast<uint64_t> (ticTaiNs);
                    referencePtpNs = driverPtpNs;
                    haveReference = true;
                }

                previousSac = snapshot.sac;
            }
        }

        if (index + 1 < samples)
            std::this_thread::sleep_for (std::chrono::milliseconds (intervalMs));
    }
}
