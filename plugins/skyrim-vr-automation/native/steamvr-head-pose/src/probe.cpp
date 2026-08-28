// SPDX-License-Identifier: GPL-3.0-or-later

#include <openvr.h>

#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>

namespace {

void PrintPose(const char* name, const vr::TrackedDevicePose_t& pose)
{
    const auto& matrix = pose.mDeviceToAbsoluteTracking;
    std::cout << '"' << name << "\":{";
    std::cout << "\"connected\":" << (pose.bDeviceIsConnected ? "true" : "false") << ',';
    std::cout << "\"valid\":" << (pose.bPoseIsValid ? "true" : "false") << ',';
    std::cout << "\"trackingResult\":" << static_cast<int>(pose.eTrackingResult) << ',';
    std::cout << "\"position\":[" << matrix.m[0][3] << ',' << matrix.m[1][3] << ',' << matrix.m[2][3] << ']';
    std::cout << '}';
}

}  // namespace

int main()
{
    vr::EVRInitError error = vr::VRInitError_None;
    auto* system = vr::VR_Init(&error, vr::VRApplication_Background);
    if (error != vr::VRInitError_None || !system) {
        std::cout << "{\"ok\":false,\"state\":\"openvr-init-failed\",\"errorCode\":"
                  << static_cast<int>(error) << ",\"error\":\""
                  << vr::VR_GetVRInitErrorAsEnglishDescription(error) << "\"}\n";
        return 2;
    }

    std::array<vr::TrackedDevicePose_t, vr::k_unMaxTrackedDeviceCount> standing{};
    std::array<vr::TrackedDevicePose_t, vr::k_unMaxTrackedDeviceCount> raw{};
    system->GetDeviceToAbsoluteTrackingPose(
        vr::TrackingUniverseStanding, 0.0F, standing.data(), static_cast<std::uint32_t>(standing.size()));
    system->GetDeviceToAbsoluteTrackingPose(
        vr::TrackingUniverseRawAndUncalibrated, 0.0F, raw.data(), static_cast<std::uint32_t>(raw.size()));

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "{\"ok\":true,\"state\":\"pose-observed\",\"hmdIndex\":0,";
    PrintPose("standing", standing[vr::k_unTrackedDeviceIndex_Hmd]);
    std::cout << ',';
    PrintPose("raw", raw[vr::k_unTrackedDeviceIndex_Hmd]);
    std::cout << "}\n";
    vr::VR_Shutdown();
    return 0;
}
