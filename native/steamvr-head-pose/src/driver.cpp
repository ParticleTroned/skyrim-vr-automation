// SPDX-License-Identifier: GPL-3.0-or-later

#include <openvr_driver.h>

#include <Windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>

namespace {

constexpr char kSettingsSection[] = "driver_codex_head_pose";
constexpr char kDefaultSerial[] = "CSX-NULL-HMD-POSE-1";
constexpr char kDefaultModel[] = "CSX Synthetic Head Pose";
constexpr wchar_t kPoseMapName[] = L"Local\\CSXVRHeadPose-v1";
constexpr std::uint32_t kPoseMagic = 0x48505343;  // "CSPH" in little endian.
constexpr std::uint16_t kPoseVersion = 1;
constexpr std::uint32_t kPoseEnabled = 1U << 0U;
constexpr std::uint32_t kPoseStatusWaiting = 0;
constexpr std::uint32_t kPoseStatusApplied = 1;
constexpr std::uint32_t kPoseStatusRejected = 2;
constexpr double kPi = 3.14159265358979323846;

struct alignas(8) SharedPoseState {
    std::uint32_t magic;
    std::uint16_t version;
    std::uint16_t size;
    volatile std::uint64_t requestedSequence;
    volatile std::uint64_t appliedSequence;
    volatile std::uint32_t status;
    std::uint32_t flags;
    double positionX;
    double positionY;
    double positionZ;
    double quaternionW;
    double quaternionX;
    double quaternionY;
    double quaternionZ;
};

static_assert(sizeof(SharedPoseState) == 88);

struct PoseValue {
    std::array<double, 3> position{0.0, 1.68, 0.0};
    std::array<double, 4> quaternion{1.0, 0.0, 0.0, 0.0};
    bool enabled{true};
};

vr::HmdQuaternion_t Quaternion(double w, double x, double y, double z)
{
    return vr::HmdQuaternion_t{w, x, y, z};
}

std::array<double, 4> QuaternionFromEulerDegrees(double yaw, double pitch, double roll)
{
    const auto halfYaw = yaw * kPi / 360.0;
    const auto halfPitch = pitch * kPi / 360.0;
    const auto halfRoll = roll * kPi / 360.0;
    const auto cy = std::cos(halfYaw);
    const auto sy = std::sin(halfYaw);
    const auto cp = std::cos(halfPitch);
    const auto sp = std::sin(halfPitch);
    const auto cr = std::cos(halfRoll);
    const auto sr = std::sin(halfRoll);

    // Intrinsic yaw (Y), pitch (X), roll (Z).
    return {
        cy * cp * cr + sy * sp * sr,
        cy * sp * cr + sy * cp * sr,
        sy * cp * cr - cy * sp * sr,
        cy * cp * sr - sy * sp * cr,
    };
}

bool IsFinitePose(const PoseValue& pose)
{
    for (const auto value : pose.position) {
        if (!std::isfinite(value) || std::abs(value) > 1000.0) {
            return false;
        }
    }
    double normSquared = 0.0;
    for (const auto value : pose.quaternion) {
        if (!std::isfinite(value)) {
            return false;
        }
        normSquared += value * value;
    }
    return normSquared > 0.25 && normSquared < 4.0;
}

void NormalizeQuaternion(PoseValue& pose)
{
    double normSquared = 0.0;
    for (const auto value : pose.quaternion) {
        normSquared += value * value;
    }
    const auto inverseNorm = 1.0 / std::sqrt(normSquared);
    for (auto& value : pose.quaternion) {
        value *= inverseNorm;
    }
}

void Log(const std::string& message)
{
    if (auto* logger = vr::VRDriverLog()) {
        logger->Log(("codex_head_pose: " + message + "\n").c_str());
    }
}

std::string ReadStringSetting(const char* key, const char* fallback)
{
    char buffer[1024]{};
    vr::EVRSettingsError error = vr::VRSettingsError_None;
    vr::VRSettings()->GetString(kSettingsSection, key, buffer, sizeof(buffer), &error);
    return error == vr::VRSettingsError_None && buffer[0] != '\0' ? buffer : fallback;
}

double ReadFloatSetting(const char* key, double fallback)
{
    vr::EVRSettingsError error = vr::VRSettingsError_None;
    const auto value = vr::VRSettings()->GetFloat(kSettingsSection, key, &error);
    return error == vr::VRSettingsError_None && std::isfinite(value) ? value : fallback;
}

bool ReadBoolSetting(const char* key, bool fallback)
{
    vr::EVRSettingsError error = vr::VRSettingsError_None;
    const auto value = vr::VRSettings()->GetBool(kSettingsSection, key, &error);
    return error == vr::VRSettingsError_None ? value : fallback;
}

class SharedPoseChannel {
public:
    ~SharedPoseChannel()
    {
        if (state_) {
            UnmapViewOfFile(state_);
        }
        if (mapping_) {
            CloseHandle(mapping_);
        }
    }

    bool Initialize(const PoseValue& initialPose)
    {
        mapping_ = CreateFileMappingW(
            INVALID_HANDLE_VALUE,
            nullptr,
            PAGE_READWRITE,
            0,
            static_cast<DWORD>(sizeof(SharedPoseState)),
            kPoseMapName);
        if (!mapping_) {
            Log("CreateFileMappingW failed with Win32 error " + std::to_string(GetLastError()));
            return false;
        }
        const auto existed = GetLastError() == ERROR_ALREADY_EXISTS;
        state_ = static_cast<SharedPoseState*>(
            MapViewOfFile(mapping_, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(SharedPoseState)));
        if (!state_) {
            Log("MapViewOfFile failed with Win32 error " + std::to_string(GetLastError()));
            return false;
        }

        if (!existed || state_->magic != kPoseMagic || state_->version != kPoseVersion ||
            state_->size != sizeof(SharedPoseState)) {
            std::memset(state_, 0, sizeof(SharedPoseState));
            state_->magic = kPoseMagic;
            state_->version = kPoseVersion;
            state_->size = sizeof(SharedPoseState);
            state_->requestedSequence = 1;
            MemoryBarrier();
            WritePose(initialPose);
            state_->status = kPoseStatusWaiting;
            MemoryBarrier();
            state_->requestedSequence = 2;
        }
        return true;
    }

    bool ReadPending(PoseValue& value, std::uint64_t& sequence)
    {
        if (!state_) {
            return false;
        }
        const auto first = state_->requestedSequence;
        MemoryBarrier();
        if (first == 0 || (first & 1U) != 0 || first == state_->appliedSequence) {
            return false;
        }

        value.enabled = (state_->flags & kPoseEnabled) != 0;
        value.position = {state_->positionX, state_->positionY, state_->positionZ};
        value.quaternion = {
            state_->quaternionW,
            state_->quaternionX,
            state_->quaternionY,
            state_->quaternionZ,
        };
        MemoryBarrier();
        const auto second = state_->requestedSequence;
        if (first != second || (second & 1U) != 0) {
            return false;
        }
        sequence = second;
        return true;
    }

    void Acknowledge(std::uint64_t sequence, bool accepted)
    {
        if (!state_) {
            return;
        }
        state_->status = accepted ? kPoseStatusApplied : kPoseStatusRejected;
        MemoryBarrier();
        state_->appliedSequence = sequence;
    }

private:
    void WritePose(const PoseValue& pose)
    {
        state_->flags = pose.enabled ? kPoseEnabled : 0;
        state_->positionX = pose.position[0];
        state_->positionY = pose.position[1];
        state_->positionZ = pose.position[2];
        state_->quaternionW = pose.quaternion[0];
        state_->quaternionX = pose.quaternion[1];
        state_->quaternionY = pose.quaternion[2];
        state_->quaternionZ = pose.quaternion[3];
    }

    HANDLE mapping_{nullptr};
    SharedPoseState* state_{nullptr};
};

class HeadPoseDevice final : public vr::ITrackedDeviceServerDriver {
public:
    HeadPoseDevice(std::string serial, std::string model, PoseValue initialPose) :
        serial_(std::move(serial)), model_(std::move(model)), pose_(initialPose)
    {}

    vr::EVRInitError Activate(vr::TrackedDeviceIndex_t objectId) override
    {
        objectId_ = objectId;
        const auto properties = vr::VRProperties()->TrackedDeviceToPropertyContainer(objectId_);
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_ModelNumber_String, model_.c_str());
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_RenderModelName_String, "generic_hmd");
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_TrackingSystemName_String, "codex_head_pose");
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_ManufacturerName_String, "Treatid2");
        vr::VRProperties()->SetBoolProperty(properties, vr::Prop_NeverTracked_Bool, false);
        vr::VRProperties()->SetBoolProperty(properties, vr::Prop_DeviceProvidesBatteryStatus_Bool, false);
        vr::VRProperties()->SetUint64Property(properties, vr::Prop_CurrentUniverseId_Uint64, 2);

        if (!channel_.Initialize(pose_)) {
            return vr::VRInitError_Driver_Failed;
        }
        Log("activated device " + serial_ + " with shared-memory contract Local\\CSXVRHeadPose-v1");
        return vr::VRInitError_None;
    }

    void Deactivate() override { objectId_ = vr::k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() override {}
    void* GetComponent(const char*) override { return nullptr; }

    void DebugRequest(const char*, char* response, std::uint32_t responseSize) override
    {
        if (response && responseSize > 0) {
            response[0] = '\0';
        }
    }

    vr::DriverPose_t GetPose() override
    {
        vr::DriverPose_t result{};
        result.qWorldFromDriverRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        result.qDriverFromHeadRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        result.qRotation = Quaternion(
            pose_.quaternion[0], pose_.quaternion[1], pose_.quaternion[2], pose_.quaternion[3]);
        result.vecPosition[0] = pose_.position[0];
        result.vecPosition[1] = pose_.position[1];
        result.vecPosition[2] = pose_.position[2];
        result.result = vr::TrackingResult_Running_OK;
        result.poseIsValid = pose_.enabled;
        result.deviceIsConnected = true;
        result.shouldApplyHeadModel = false;
        return result;
    }

    void RunFrame()
    {
        PoseValue candidate{};
        std::uint64_t sequence = 0;
        if (channel_.ReadPending(candidate, sequence)) {
            const auto accepted = IsFinitePose(candidate);
            if (accepted) {
                NormalizeQuaternion(candidate);
                pose_ = candidate;
            }
            channel_.Acknowledge(sequence, accepted);
            Log(std::string(accepted ? "applied" : "rejected") + " pose sequence " +
                std::to_string(sequence));
        }
        if (objectId_ != vr::k_unTrackedDeviceIndexInvalid) {
            vr::VRServerDriverHost()->TrackedDevicePoseUpdated(objectId_, GetPose(), sizeof(vr::DriverPose_t));
        }
    }

    const std::string& Serial() const { return serial_; }

private:
    vr::TrackedDeviceIndex_t objectId_{vr::k_unTrackedDeviceIndexInvalid};
    std::string serial_;
    std::string model_;
    PoseValue pose_;
    SharedPoseChannel channel_;
};

class HeadPoseProvider final : public vr::IServerTrackedDeviceProvider {
public:
    vr::EVRInitError Init(vr::IVRDriverContext* context) override
    {
        VR_INIT_SERVER_DRIVER_CONTEXT(context);
        if (!ReadBoolSetting("enable", false)) {
            Log("disabled by driver_codex_head_pose.enable");
            return vr::VRInitError_None;
        }

        PoseValue initial{};
        initial.position = {
            ReadFloatSetting("positionX", 0.0),
            ReadFloatSetting("eyeHeightMeters", 1.68),
            ReadFloatSetting("positionZ", 0.0),
        };
        initial.quaternion = QuaternionFromEulerDegrees(
            ReadFloatSetting("yawDegrees", 0.0),
            ReadFloatSetting("pitchDegrees", 0.0),
            ReadFloatSetting("rollDegrees", 0.0));
        if (!IsFinitePose(initial)) {
            Log("initial pose settings are invalid");
            return vr::VRInitError_Driver_Failed;
        }
        NormalizeQuaternion(initial);

        device_ = std::make_unique<HeadPoseDevice>(
            ReadStringSetting("serialNumber", kDefaultSerial),
            ReadStringSetting("modelNumber", kDefaultModel),
            initial);
        if (!vr::VRServerDriverHost()->TrackedDeviceAdded(
                device_->Serial().c_str(), vr::TrackedDeviceClass_GenericTracker, device_.get())) {
            Log("TrackedDeviceAdded rejected the synthetic head-pose device");
            device_.reset();
            return vr::VRInitError_Driver_Failed;
        }
        Log("registered synthetic head-pose device at configured standing pose");
        return vr::VRInitError_None;
    }

    void Cleanup() override
    {
        device_.reset();
        vr::CleanupDriverContext();
    }

    const char* const* GetInterfaceVersions() override { return vr::k_InterfaceVersions; }
    void RunFrame() override
    {
        if (device_) {
            device_->RunFrame();
        }
    }
    bool ShouldBlockStandbyMode() override { return false; }
    void EnterStandby() override {}
    void LeaveStandby() override {}

private:
    std::unique_ptr<HeadPoseDevice> device_;
};

HeadPoseProvider g_provider;

}  // namespace

#define HMD_DLL_EXPORT extern "C" __declspec(dllexport)

HMD_DLL_EXPORT void* HmdDriverFactory(const char* interfaceName, int* returnCode)
{
    if (std::strcmp(vr::IServerTrackedDeviceProvider_Version, interfaceName) == 0) {
        return &g_provider;
    }
    if (returnCode) {
        *returnCode = vr::VRInitError_Init_InterfaceNotFound;
    }
    return nullptr;
}
