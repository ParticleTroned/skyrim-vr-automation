// SPDX-License-Identifier: GPL-3.0-or-later

#include <openvr.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <string>

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

std::string JsonEscape(const char* value)
{
    std::string escaped;
    if (!value) {
        return escaped;
    }
    for (const auto character : std::string(value)) {
        if (character == '\\' || character == '"') {
            escaped.push_back('\\');
        }
        escaped.push_back(character);
    }
    return escaped;
}

bool IsFiniteEyeTransform(const vr::HmdMatrix34_t& transform)
{
    for (const auto& row : transform.m) {
        for (const auto value : row) {
            if (!std::isfinite(value)) {
                return false;
            }
        }
    }
    return true;
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
    const auto leftEye = system->GetEyeToHeadTransform(vr::Eye_Left);
    const auto rightEye = system->GetEyeToHeadTransform(vr::Eye_Right);
    const auto dx = static_cast<double>(leftEye.m[0][3] - rightEye.m[0][3]);
    const auto dy = static_cast<double>(leftEye.m[1][3] - rightEye.m[1][3]);
    const auto dz = static_cast<double>(leftEye.m[2][3] - rightEye.m[2][3]);
    const auto eyeSeparation = std::sqrt(dx * dx + dy * dy + dz * dz);
    std::uint32_t renderWidth = 0;
    std::uint32_t renderHeight = 0;
    system->GetRecommendedRenderTargetSize(&renderWidth, &renderHeight);
    std::array<char, 4096> runtimePath{};
    std::uint32_t requiredRuntimePath = 0;
    const auto runtimePathAvailable = vr::VR_GetRuntimePath(
        runtimePath.data(), static_cast<std::uint32_t>(runtimePath.size()), &requiredRuntimePath);
    const auto stereoValid = IsFiniteEyeTransform(leftEye) && IsFiniteEyeTransform(rightEye) &&
        eyeSeparation >= 0.01 && eyeSeparation <= 0.20 && renderWidth > 0 && renderHeight > 0 &&
        runtimePathAvailable && requiredRuntimePath > 1 && requiredRuntimePath <= runtimePath.size();

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "{\"ok\":true,\"state\":\"pose-observed\",\"hmdIndex\":0,";
    PrintPose("standing", standing[vr::k_unTrackedDeviceIndex_Hmd]);
    std::cout << ',';
    PrintPose("raw", raw[vr::k_unTrackedDeviceIndex_Hmd]);
    std::cout << ",\"stereo\":{";
    std::cout << "\"valid\":" << (stereoValid ? "true" : "false") << ',';
    std::cout << "\"leftEyeTranslation\":[" << leftEye.m[0][3] << ',' << leftEye.m[1][3] << ',' << leftEye.m[2][3] << "],";
    std::cout << "\"rightEyeTranslation\":[" << rightEye.m[0][3] << ',' << rightEye.m[1][3] << ',' << rightEye.m[2][3] << "],";
    std::cout << "\"eyeSeparationMeters\":" << eyeSeparation << ',';
    std::cout << "\"recommendedRenderTarget\":[" << renderWidth << ',' << renderHeight << "]},";
    std::cout << "\"runtimePath\":\"" << JsonEscape(runtimePath.data()) << "\"";
    std::cout << "}\n";
    vr::VR_Shutdown();
    return stereoValid ? 0 : 3;
}
