/*
** i_gamecontroller.mm
**
** Handles GameController.framework extended gamepads on macOS.
**
**---------------------------------------------------------------------------
**
** Copyright 2026 UZDoom Maintainers and Contributors
**
** SPDX-License-Identifier: GPL-3.0-or-later
**
**---------------------------------------------------------------------------
**
*/

#import <GameController/GameController.h>

#include <algorithm>
#include <cmath>

#include "d_eventbase.h"
#include "m_argv.h"
#include "m_joy.h"
#include "keydef.h"
#include "tarray.h"
#include "zstring.h"

EXTERN_CVAR(Bool, use_joystick)
EXTERN_FARG(nojoy);

namespace
{

static const EAxisCodes ControllerAxisCodes[][2] =
{
	{ AXIS_CODE_PAD_LTHUMB_RIGHT, AXIS_CODE_PAD_LTHUMB_LEFT },
	{ AXIS_CODE_PAD_LTHUMB_DOWN, AXIS_CODE_PAD_LTHUMB_UP },
	{ AXIS_CODE_PAD_RTHUMB_RIGHT, AXIS_CODE_PAD_RTHUMB_LEFT },
	{ AXIS_CODE_PAD_RTHUMB_DOWN, AXIS_CODE_PAD_RTHUMB_UP },
	{ AXIS_CODE_PAD_LTRIGGER, AXIS_CODE_NULL },
	{ AXIS_CODE_PAD_RTRIGGER, AXIS_CODE_NULL }
};

enum PhysicalButtonIndex
{
	PhysicalButtonA,
	PhysicalButtonB,
	PhysicalButtonX,
	PhysicalButtonY,
	PhysicalButtonDPadUp,
	PhysicalButtonDPadDown,
	PhysicalButtonDPadLeft,
	PhysicalButtonDPadRight,
	PhysicalButtonMenu,
	PhysicalButtonOptions,
	PhysicalButtonLeftShoulder,
	PhysicalButtonRightShoulder,
	PhysicalButtonLeftThumbstick,
	PhysicalButtonRightThumbstick,
	PhysicalButtonCount
};

static const int PhysicalButtonKeys[PhysicalButtonCount] =
{
	KEY_PAD_A,
	KEY_PAD_B,
	KEY_PAD_X,
	KEY_PAD_Y,
	KEY_PAD_DPAD_UP,
	KEY_PAD_DPAD_DOWN,
	KEY_PAD_DPAD_LEFT,
	KEY_PAD_DPAD_RIGHT,
	KEY_PAD_START,
	KEY_PAD_BACK,
	KEY_PAD_LSHOULDER,
	KEY_PAD_RSHOULDER,
	KEY_PAD_LTHUMB,
	KEY_PAD_RTHUMB
};

enum AxisIndex
{
	AxisLeftX,
	AxisLeftY,
	AxisRightX,
	AxisRightY,
	AxisLeftTrigger,
	AxisRightTrigger,
	AxisCount
};

struct AxisInfo
{
	const char *Name;
	float DeadZone;
	float Multiplier;
	float DigitalThreshold;
	EJoyCurve ResponseCurvePreset;
	CubicBezier ResponseCurve;
	float Value;
	uint8_t ButtonValue;
};

static const char *StringOrFallback(NSString *string, const char *fallback)
{
	if (string == nil || string.length == 0 || string.UTF8String == nullptr)
	{
		return fallback;
	}
	return string.UTF8String;
}

class GameControllerDevice final : public IJoystickConfig
{
public:
	explicit GameControllerDevice(GCController *controller)
		: m_controller([controller retain])
		, m_profile(controller.extendedGamepad)
		, m_sensitivity(JOYSENSITIVITY_DEFAULT)
		, m_enabled(true)
		, m_physicalButtons(0)
	{
		const char *vendor = StringOrFallback(controller.vendorName, "Unknown Vendor");
		const char *category = StringOrFallback(controller.productCategory, "Unknown Controller Category");
		m_name.Format("%s %s", vendor, category);
		// Configuration intentionally follows the model, not an individual connection.
		m_identifier.Format("GameController:%s:%s", vendor, category);
		SetDefaultConfig();
		M_LoadJoystickConfig(this);
	}

	~GameControllerDevice() override
	{
		Neutralize();
		M_SaveJoystickConfig(this);
		[m_controller release];
	}

	bool Matches(GCController *controller) const { return m_controller == controller; }

	FString GetName() override { return m_name; }
	float GetSensitivity() override { return m_sensitivity; }
	void SetSensitivity(float scale) override { m_sensitivity = scale; }

	bool HasHaptics() override { return false; }
	float GetHapticsStrength() override { return 0.0f; }
	void SetHapticsStrength(float) override { }

	int GetNumAxes() override { return AxisCount; }
	float GetAxisDeadZone(int axis) override { return IsAxisValid(axis) ? m_axes[axis].DeadZone : 0.0f; }
	const char *GetAxisName(int axis) override { return IsAxisValid(axis) ? m_axes[axis].Name : "Invalid"; }
	float GetAxisScale(int axis) override { return IsAxisValid(axis) ? m_axes[axis].Multiplier : 0.0f; }
	float GetAxisDigitalThreshold(int axis) override { return IsAxisValid(axis) ? m_axes[axis].DigitalThreshold : JOYTHRESH_DEFAULT; }
	EJoyCurve GetAxisResponseCurve(int axis) override { return IsAxisValid(axis) ? m_axes[axis].ResponseCurvePreset : JOYCURVE_DEFAULT; }
	float GetAxisResponseCurvePoint(int axis, int point) override
	{
		return IsAxisValid(axis) && unsigned(point) < 4 ? m_axes[axis].ResponseCurve.pts[point] : 0.0f;
	}

	void SetAxisDeadZone(int axis, float zone) override
	{
		if (IsAxisValid(axis)) m_axes[axis].DeadZone = std::clamp(zone, 0.0f, 1.0f);
	}
	void SetAxisScale(int axis, float scale) override
	{
		if (IsAxisValid(axis)) m_axes[axis].Multiplier = scale;
	}
	void SetAxisDigitalThreshold(int axis, float threshold) override
	{
		if (IsAxisValid(axis)) m_axes[axis].DigitalThreshold = threshold;
	}
	void SetAxisResponseCurve(int axis, EJoyCurve preset) override
	{
		if (!IsAxisValid(axis) || preset < JOYCURVE_CUSTOM || preset >= NUM_JOYCURVE) return;
		m_axes[axis].ResponseCurvePreset = preset;
		if (preset != JOYCURVE_CUSTOM) m_axes[axis].ResponseCurve = JOYCURVE[preset];
	}
	void SetAxisResponseCurvePoint(int axis, int point, float value) override
	{
		if (IsAxisValid(axis) && unsigned(point) < 4)
		{
			m_axes[axis].ResponseCurvePreset = JOYCURVE_CUSTOM;
			m_axes[axis].ResponseCurve.pts[point] = value;
		}
	}

	bool GetEnabled() override { return m_enabled; }
	void SetEnabled(bool enabled) override
	{
		if (m_enabled && !enabled) Neutralize();
		m_enabled = enabled;
	}

	bool AllowsEnabledInBackground() override { return false; }
	bool GetEnabledInBackground() override { return false; }
	void SetEnabledInBackground(bool) override { }

	bool IsSensitivityDefault() override { return m_sensitivity == JOYSENSITIVITY_DEFAULT; }
	bool IsHapticsStrengthDefault() override { return true; }
	bool IsAxisDeadZoneDefault(int axis) override { return IsAxisValid(axis) && m_axes[axis].DeadZone == DefaultDeadZone(axis); }
	bool IsAxisScaleDefault(int axis) override { return IsAxisValid(axis) && m_axes[axis].Multiplier == JOYSENSITIVITY_DEFAULT; }
	bool IsAxisDigitalThresholdDefault(int axis) override { return IsAxisValid(axis) && m_axes[axis].DigitalThreshold == DefaultThreshold(axis); }
	bool IsAxisResponseCurveDefault(int axis) override { return IsAxisValid(axis) && m_axes[axis].ResponseCurvePreset == JOYCURVE_DEFAULT; }

	void SetDefaultConfig() override
	{
		static const char *AxisNames[AxisCount] =
		{
			"Left Stick X", "Left Stick Y", "Right Stick X", "Right Stick Y", "Left Trigger", "Right Trigger"
		};

		m_sensitivity = JOYSENSITIVITY_DEFAULT;
		for (int axis = 0; axis < AxisCount; ++axis)
		{
			m_axes[axis].Name = AxisNames[axis];
			m_axes[axis].DeadZone = JOYDEADZONE_DEFAULT;
			m_axes[axis].Multiplier = JOYSENSITIVITY_DEFAULT;
			m_axes[axis].DigitalThreshold = DefaultThreshold(axis);
			m_axes[axis].ResponseCurvePreset = JOYCURVE_DEFAULT;
			m_axes[axis].ResponseCurve = JOYCURVE[JOYCURVE_DEFAULT];
			m_axes[axis].Value = 0.0f;
			m_axes[axis].ButtonValue = 0;
		}
		m_physicalButtons = 0;
	}

	FString GetIdentifier() override { return m_identifier; }

	void ProcessInput()
	{
		UpdatePhysicalButtons();
		ProcessThumbstick(AxisLeftX, AxisLeftY, m_profile.leftThumbstick, KEY_PAD_LTHUMB_RIGHT);
		ProcessThumbstick(AxisRightX, AxisRightY, m_profile.rightThumbstick, KEY_PAD_RTHUMB_RIGHT);
		ProcessTrigger(AxisLeftTrigger, m_profile.leftTrigger, KEY_PAD_LTRIGGER);
		ProcessTrigger(AxisRightTrigger, m_profile.rightTrigger, KEY_PAD_RTRIGGER);
	}

	void AddAxes(float axes[NUM_AXIS_CODES]) const
	{
		for (int axis = 0; axis < AxisCount; ++axis)
		{
			const float value = m_axes[axis].Value * m_sensitivity * m_axes[axis].Multiplier;
			const int code = value > 0.0f ? ControllerAxisCodes[axis][0]
				: value < 0.0f ? ControllerAxisCodes[axis][1] : AXIS_CODE_NULL;
			if (code != AXIS_CODE_NULL) axes[code] += std::fabs(value);
		}
	}

	void Neutralize()
	{
		Joy_GenerateButtonEvents(m_physicalButtons, 0, PhysicalButtonCount, PhysicalButtonKeys);
		m_physicalButtons = 0;
		ReleaseAxisButtons(AxisLeftX, 4, KEY_PAD_LTHUMB_RIGHT);
		ReleaseAxisButtons(AxisRightX, 4, KEY_PAD_RTHUMB_RIGHT);
		ReleaseAxisButtons(AxisLeftTrigger, 1, KEY_PAD_LTRIGGER);
		ReleaseAxisButtons(AxisRightTrigger, 1, KEY_PAD_RTRIGGER);
		for (AxisInfo &axis : m_axes) axis.Value = 0.0f;
	}

private:
	static bool IsAxisValid(int axis) { return unsigned(axis) < AxisCount; }
	static float DefaultDeadZone(int) { return JOYDEADZONE_DEFAULT; }
	static float DefaultThreshold(int axis)
	{
		return axis == AxisLeftX || axis == AxisRightX ? JOYTHRESH_STICK_X
			: axis == AxisLeftY || axis == AxisRightY ? JOYTHRESH_STICK_Y
			: JOYTHRESH_TRIGGER;
	}

	void UpdatePhysicalButtons()
	{
		auto pressed = [](GCControllerButtonInput *button) { return button != nil && button.isPressed; };
		int buttons = 0;
		const GCExtendedGamepad *profile = m_profile;
		buttons |= pressed(profile.buttonA) << PhysicalButtonA;
		buttons |= pressed(profile.buttonB) << PhysicalButtonB;
		buttons |= pressed(profile.buttonX) << PhysicalButtonX;
		buttons |= pressed(profile.buttonY) << PhysicalButtonY;
		buttons |= pressed(profile.dpad.up) << PhysicalButtonDPadUp;
		buttons |= pressed(profile.dpad.down) << PhysicalButtonDPadDown;
		buttons |= pressed(profile.dpad.left) << PhysicalButtonDPadLeft;
		buttons |= pressed(profile.dpad.right) << PhysicalButtonDPadRight;
		buttons |= pressed(profile.buttonMenu) << PhysicalButtonMenu;
		buttons |= pressed(profile.buttonOptions) << PhysicalButtonOptions;
		buttons |= pressed(profile.leftShoulder) << PhysicalButtonLeftShoulder;
		buttons |= pressed(profile.rightShoulder) << PhysicalButtonRightShoulder;
		buttons |= pressed(profile.leftThumbstickButton) << PhysicalButtonLeftThumbstick;
		buttons |= pressed(profile.rightThumbstickButton) << PhysicalButtonRightThumbstick;
		Joy_GenerateButtonEvents(m_physicalButtons, buttons, PhysicalButtonCount, PhysicalButtonKeys);
		m_physicalButtons = buttons;
	}

	void ProcessThumbstick(int xAxis, int yAxis, GCControllerDirectionPad *stick, int base)
	{
		double x = stick.xAxis.value;
		// GameController reports up as positive; UZDoom's semantic Y axis reports up as negative.
		double y = -stick.yAxis.value;
		uint8_t buttons = 0;
		Joy_ManageThumbstick(&x, &y, m_axes[xAxis].DeadZone, m_axes[yAxis].DeadZone,
			m_axes[xAxis].DigitalThreshold, m_axes[yAxis].DigitalThreshold,
			m_axes[xAxis].ResponseCurve, m_axes[yAxis].ResponseCurve, &buttons);
		m_axes[xAxis].Value = float(x);
		m_axes[yAxis].Value = float(y);
		Joy_GenerateButtonEvents(m_axes[xAxis].ButtonValue, buttons, 4, base);
		m_axes[xAxis].ButtonValue = buttons;
	}

	void ProcessTrigger(int axis, GCControllerButtonInput *trigger, int base)
	{
		uint8_t buttons = 0;
		const double value = Joy_ManageSingleAxis(trigger.value, m_axes[axis].DeadZone,
			m_axes[axis].DigitalThreshold, m_axes[axis].ResponseCurve, &buttons);
		m_axes[axis].Value = float(value);
		Joy_GenerateButtonEvents(m_axes[axis].ButtonValue, buttons, 1, base);
		m_axes[axis].ButtonValue = buttons;
	}

	void ReleaseAxisButtons(int axis, int count, int base)
	{
		Joy_GenerateButtonEvents(m_axes[axis].ButtonValue, 0, count, base);
		m_axes[axis].ButtonValue = 0;
	}

	GCController *m_controller;
	GCExtendedGamepad *m_profile;
	FString m_name;
	FString m_identifier;
	AxisInfo m_axes[AxisCount];
	float m_sensitivity;
	bool m_enabled;
	int m_physicalButtons;
};

class GameControllerManager
{
public:
	GameControllerManager()
		: m_connectObserver(nil)
		, m_disconnectObserver(nil)
		, m_lastUseJoystick(use_joystick)
	{
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		m_connectObserver = [center addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
			usingBlock:^(NSNotification *notification) { AddController((GCController *)notification.object); }];
		m_disconnectObserver = [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
			usingBlock:^(NSNotification *notification) { RemoveController((GCController *)notification.object); }];

		// Observe first, then enumerate, so a connection cannot be missed between the two operations.
		for (GCController *controller in GCController.controllers) AddController(controller);
	}

	~GameControllerManager()
	{
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		if (m_connectObserver != nil) [center removeObserver:m_connectObserver];
		if (m_disconnectObserver != nil) [center removeObserver:m_disconnectObserver];
		m_connectObserver = nil;
		m_disconnectObserver = nil;
		NeutralizeAll();
		m_controllers.DeleteAndClear();
	}

	void GetJoysticks(TArray<IJoystickConfig *> &sticks)
	{
		for (GameControllerDevice *controller : m_controllers) sticks.Push(controller);
	}

	void ProcessInput()
	{
		if (m_lastUseJoystick && !use_joystick) NeutralizeAll();
		m_lastUseJoystick = use_joystick;
		if (!use_joystick) return;
		for (GameControllerDevice *controller : m_controllers)
		{
			if (controller->GetEnabled()) controller->ProcessInput();
		}
	}

	void AddAxes(float axes[NUM_AXIS_CODES]) const
	{
		for (GameControllerDevice *controller : m_controllers)
		{
			if (controller->GetEnabled()) controller->AddAxes(axes);
		}
	}

	void AddController(GCController *controller)
	{
		if (controller == nil || controller.extendedGamepad == nil) return;
		for (GameControllerDevice *device : m_controllers)
		{
			if (device->Matches(controller)) return;
		}
		m_controllers.Push(new GameControllerDevice(controller));
		PostDeviceChangeEvent();
	}

	void RemoveController(GCController *controller)
	{
		for (unsigned int i = 0; i < m_controllers.Size(); ++i)
		{
			if (!m_controllers[i]->Matches(controller)) continue;
			m_controllers[i]->Neutralize();
			m_controllers.Delete(i);
			PostDeviceChangeEvent();
			return;
		}
	}

private:
	void NeutralizeAll()
	{
		for (GameControllerDevice *controller : m_controllers) controller->Neutralize();
	}

	static void PostDeviceChangeEvent()
	{
		event_t event = { EV_DeviceChange };
		D_PostEvent(&event);
	}

	TDeletingArray<GameControllerDevice *> m_controllers;
	id m_connectObserver;
	id m_disconnectObserver;
	bool m_lastUseJoystick;
};

GameControllerManager *s_gameControllerManager = nullptr;

} // unnamed namespace

void I_ShutdownInput()
{
	delete s_gameControllerManager;
	s_gameControllerManager = nullptr;
}

void I_GetJoysticks(TArray<IJoystickConfig *> &sticks)
{
	sticks.Clear();
	// Devices need GameConfig while their destructors save settings, so creation is deliberately lazy.
	if (s_gameControllerManager == nullptr && !Args->CheckParm(FArg_nojoy))
	{
		s_gameControllerManager = new GameControllerManager;
	}
	if (s_gameControllerManager != nullptr) s_gameControllerManager->GetJoysticks(sticks);
}

void I_GetAxes(float axes[NUM_AXIS_CODES])
{
	for (int i = 0; i < NUM_AXIS_CODES; ++i) axes[i] = 0.0f;
	if (use_joystick && s_gameControllerManager != nullptr) s_gameControllerManager->AddAxes(axes);
}

IJoystickConfig *I_UpdateDeviceList()
{
	// GameController notifications keep the list current and menu pointers are non-owning.
	return nullptr;
}

void I_ProcessJoysticks()
{
	if (s_gameControllerManager != nullptr) s_gameControllerManager->ProcessInput();
}

void I_Rumble(double, double, double, double)
{
	// GameController haptics are intentionally outside this backend's standard-control scope.
}
