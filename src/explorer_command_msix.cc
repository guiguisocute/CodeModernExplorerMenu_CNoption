// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.
#include <fmt/core.h>
#include <iostream>
#include <fstream>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <filesystem>
#include <algorithm>
#include <string>
#include <utility>
#include <optional>
#include <vector>
#include <shlwapi.h>
#include <shobjidl_core.h>
#include <userenv.h>
#include <appmodel.h>
#include <wrl/module.h>
#include <wrl/implements.h>
#include <wrl/client.h>
#include "wil/stl.h"
#include "wil/filesystem.h"
#include "wil/win32_helpers.h"
#include <wil/cppwinrt.h>
#include <wil/resource.h>
#include <wil/com.h>

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::InhibitRoOriginateError;
using Microsoft::WRL::Module;
using Microsoft::WRL::ModuleType;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::Make;

extern "C" BOOL WINAPI DllMain(HINSTANCE instance,
                               DWORD reason,
                               LPVOID reserved) {
  switch (reason) {
    case DLL_PROCESS_ATTACH:
    case DLL_PROCESS_DETACH:
    case DLL_THREAD_ATTACH:
    case DLL_THREAD_DETACH:
      break;
  }

  return true;
}

namespace {
  enum class VSCodeVariant {
    Stable,
    Insiders,
  };

  std::wstring QuoteForCommandLineArg(const std::wstring& arg);

  // 参考实现来自 Chromium：
  // https://source.chromium.org/chromium/chromium/src/+/main:base/command_line.cc;l=109-159

  bool IsRunningPackaged() {
    UINT32 length = 0;
    LONG rc = GetCurrentPackageFullName(&length, nullptr);
    return rc != APPMODEL_ERROR_NO_PACKAGE;
  }

  std::wstring GetEnvVar(const wchar_t* name) {
    DWORD len = GetEnvironmentVariableW(name, nullptr, 0);
    if (!len) {
      return {};
    }
    std::wstring value(len, L'\0');
    DWORD written = GetEnvironmentVariableW(name, value.data(), len);
    if (!written || written >= len) {
      return {};
    }
    value.resize(written);
    return value;
  }

  std::optional<std::filesystem::path> FindVSCodeExeForVariant(bool insiders) {
    const wchar_t* dir_name = insiders ? L"Microsoft VS Code Insiders" : L"Microsoft VS Code";
    const wchar_t* exe_name = insiders ? L"Code - Insiders.exe" : L"Code.exe";

    // 常见安装位置。
    std::wstring local = GetEnvVar(L"LOCALAPPDATA");
    if (!local.empty()) {
      std::filesystem::path p = std::filesystem::path(local) / L"Programs" / dir_name / exe_name;
      if (std::filesystem::exists(p)) {
        return p;
      }
    }

    std::wstring pf = GetEnvVar(L"ProgramFiles");
    if (!pf.empty()) {
      std::filesystem::path p = std::filesystem::path(pf) / dir_name / exe_name;
      if (std::filesystem::exists(p)) {
        return p;
      }
    }

    std::wstring pfx86 = GetEnvVar(L"ProgramFiles(x86)");
    if (!pfx86.empty()) {
      std::filesystem::path p = std::filesystem::path(pfx86) / dir_name / exe_name;
      if (std::filesystem::exists(p)) {
        return p;
      }
    }

    // 基于 PATH 的发现。
    auto try_search_path = [](const wchar_t* file) -> std::optional<std::filesystem::path> {
      DWORD need = SearchPathW(nullptr, file, nullptr, 0, nullptr, nullptr);
      if (!need) {
        return std::nullopt;
      }
      std::wstring buf(need, L'\0');
      DWORD written = SearchPathW(nullptr, file, nullptr, need, buf.data(), nullptr);
      if (!written || written >= need) {
        return std::nullopt;
      }
      buf.resize(written);
      std::filesystem::path p = buf;
      if (std::filesystem::exists(p)) {
        return p;
      }
      return std::nullopt;
    };

    // 一些环境会提供别名：code.exe / code-insiders.exe。
    if (insiders) {
      if (auto p = try_search_path(L"code-insiders.exe")) {
        return p;
      }
      if (auto cmd = try_search_path(L"code-insiders.cmd")) {
        auto bin_dir = cmd->parent_path();
        auto resolved = bin_dir / L".." / L".." / exe_name;
        resolved = resolved.lexically_normal();
        if (std::filesystem::exists(resolved)) {
          return resolved;
        }
      }
    } else {
      if (auto p = try_search_path(L"code.exe")) {
        return p;
      }
      if (auto cmd = try_search_path(L"code.cmd")) {
        auto bin_dir = cmd->parent_path();
        auto resolved = bin_dir / L".." / L".." / exe_name;
        resolved = resolved.lexically_normal();
        if (std::filesystem::exists(resolved)) {
          return resolved;
        }
      }
    }

    return std::nullopt;
  }

  std::optional<std::filesystem::path> FindVSCodeExePreferVariant(bool prefer_insiders) {
    if (prefer_insiders) {
      if (auto p = FindVSCodeExeForVariant(true)) {
        return p;
      }
      return FindVSCodeExeForVariant(false);
    }
    if (auto p = FindVSCodeExeForVariant(false)) {
      return p;
    }
    return FindVSCodeExeForVariant(true);
  }

  std::optional<std::filesystem::path> FindVSCodeExeForVariant(VSCodeVariant variant) {
    return FindVSCodeExeForVariant(variant == VSCodeVariant::Insiders);
  }

  const wchar_t* GetVariantTitle(VSCodeVariant variant) {
    if (variant == VSCodeVariant::Insiders) {
      return L"通过 Code Insiders 打开";
    }
    return L"通过 Code（正式版）打开";
  }

  bool IsVariantAvailable(VSCodeVariant variant) {
    return FindVSCodeExeForVariant(variant).has_value();
  }

  bool AnyVariantAvailable() {
    return IsVariantAvailable(VSCodeVariant::Stable) || IsVariantAvailable(VSCodeVariant::Insiders);
  }

  HRESULT DuplicateVariantIcon(VSCodeVariant variant, PWSTR* icon) {
    if (icon == nullptr) {
      return E_POINTER;
    }
    *icon = nullptr;

    if (auto exe = FindVSCodeExeForVariant(variant)) {
      std::wstring exe_icon = exe->wstring();
      exe_icon.append(L",0");
      return SHStrDupW(exe_icon.c_str(), icon);
    }

    return E_FAIL;
  }

  HRESULT BuildSelectionArgs(IShellItemArray* items, std::wstring* args) {
    if (args == nullptr) {
      return E_POINTER;
    }

    args->clear();
    if (!items) {
      return S_OK;
    }

    DWORD count = 0;
    RETURN_IF_FAILED(items->GetCount(&count));
    for (DWORD i = 0; i < count; ++i) {
      ComPtr<IShellItem> item;
      auto result = items->GetItemAt(i, &item);
      if (FAILED(result) || !item) {
        continue;
      }

      wil::unique_cotaskmem_string path;
      result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
      if (FAILED(result) || !path) {
        continue;
      }

      if (!args->empty()) {
        args->push_back(L' ');
      }
      args->append(QuoteForCommandLineArg(path.get()));
    }

    return S_OK;
  }

  HRESULT LaunchVariant(VSCodeVariant variant, IShellItemArray* items) {
    auto exe = FindVSCodeExeForVariant(variant);
    if (!exe) {
      return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    }

    std::wstring args;
    RETURN_IF_FAILED(BuildSelectionArgs(items, &args));
    if (args.empty()) {
      return S_OK;
    }

    std::wstring command_line = L"--new-window ";
    command_line.append(args);
    HINSTANCE ret = ShellExecuteW(nullptr, L"open", exe->c_str(), command_line.c_str(), nullptr, SW_SHOW);
    if ((INT_PTR)ret <= HINSTANCE_ERROR) {
      return E_FAIL;
    }
    return S_OK;
  }

  std::wstring QuoteForCommandLineArg(const std::wstring& arg) {
  // 按 CommandLineToArgvW 的参数解析规则进行转义/加引号。
  // http://msdn.microsoft.com/en-us/library/17w5ykft.aspx
  std::wstring quotable_chars(L" \\\"");
  if (arg.find_first_of(quotable_chars) == std::wstring::npos) {
    // 不需要加引号。
    return arg;
  }

  std::wstring out;
  out.push_back('"');
  for (size_t i = 0; i < arg.size(); ++i) {
    if (arg[i] == '\\') {
      // 找到连续反斜杠的区间。
      size_t start = i, end = start + 1;
      for (; end < arg.size() && arg[end] == '\\'; ++end) {}
      size_t backslash_count = end - start;

      // 反斜杠仅在其后跟着双引号时才作为转义符。
      // 因为我们也会用双引号结束字符串，所以需要对“遇到双引号”或“字符串结束”两种情况进行转义。
      if (end == arg.size() || arg[end] == '"') {
        // 为了正确转义，需要输出 2 倍数量的反斜杠。
        backslash_count *= 2;
      }
      for (size_t j = 0; j < backslash_count; ++j)
        out.push_back('\\');

      // 将 i 移动到 end-1，以平衡 for 循环里的 i++。
      i = end - 1;
    } else if (arg[i] == '"') {
      out.push_back('\\');
      out.push_back('"');
    } else {
      out.push_back(arg[i]);
    }
  }
  out.push_back('"');

  return out;
}

}

class ExplorerSubCommand final : public RuntimeClass<RuntimeClassFlags<ClassicCom | InhibitRoOriginateError>, IExplorerCommand> {
 public:
  explicit ExplorerSubCommand(VSCodeVariant variant) : variant_(variant) {}

  IFACEMETHODIMP GetTitle(IShellItemArray* items, PWSTR* name) override {
    return SHStrDupW(GetVariantTitle(variant_), name);
  }

  IFACEMETHODIMP GetIcon(IShellItemArray* items, PWSTR* icon) override {
    return DuplicateVariantIcon(variant_, icon);
  }

  IFACEMETHODIMP GetToolTip(IShellItemArray* items, PWSTR* infoTip) override {
    if (infoTip == nullptr) {
      return E_POINTER;
    }
    *infoTip = nullptr;
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetCanonicalName(GUID* guidCommandName) override {
    if (guidCommandName == nullptr) {
      return E_POINTER;
    }
    *guidCommandName = GUID_NULL;
    return S_OK;
  }

  IFACEMETHODIMP GetState(IShellItemArray* items, BOOL okToBeSlow, EXPCMDSTATE* cmdState) override {
    if (cmdState == nullptr) {
      return E_POINTER;
    }
    *cmdState = IsVariantAvailable(variant_) ? ECS_ENABLED : ECS_HIDDEN;
    return S_OK;
  }

  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override {
    if (flags == nullptr) {
      return E_POINTER;
    }
    *flags = ECF_DEFAULT;
    return S_OK;
  }

  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** enumCommands) override {
    if (enumCommands == nullptr) {
      return E_POINTER;
    }
    *enumCommands = nullptr;
    return E_NOTIMPL;
  }

  IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx* bindCtx) override {
    return LaunchVariant(variant_, items);
  }

 private:
  VSCodeVariant variant_;
};

class ExplorerCommandEnumerator final : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IEnumExplorerCommand> {
 public:
  ExplorerCommandEnumerator() = default;

  explicit ExplorerCommandEnumerator(const std::vector<ComPtr<IExplorerCommand>>& commands)
      : commands_(commands), index_(0) {}

  IFACEMETHODIMP Next(ULONG count, IExplorerCommand** commands, ULONG* fetched) override {
    if (commands == nullptr) {
      return E_POINTER;
    }

    ULONG actual = 0;
    while (actual < count && index_ < commands_.size()) {
      commands[actual] = commands_[index_].Get();
      commands[actual]->AddRef();
      ++actual;
      ++index_;
    }

    if (fetched != nullptr) {
      *fetched = actual;
    }

    return actual == count ? S_OK : S_FALSE;
  }

  IFACEMETHODIMP Skip(ULONG count) override {
    index_ = (std::min)(commands_.size(), index_ + static_cast<size_t>(count));
    return index_ < commands_.size() ? S_OK : S_FALSE;
  }

  IFACEMETHODIMP Reset() override {
    index_ = 0;
    return S_OK;
  }

  IFACEMETHODIMP Clone(IEnumExplorerCommand** enumCommands) override {
    if (enumCommands == nullptr) {
      return E_POINTER;
    }

    auto clone = Make<ExplorerCommandEnumerator>(commands_);
    if (!clone) {
      *enumCommands = nullptr;
      return E_OUTOFMEMORY;
    }
    clone->index_ = index_;
    *enumCommands = clone.Detach();
    return S_OK;
  }

 private:
  std::vector<ComPtr<IExplorerCommand>> commands_;
  size_t index_ = 0;
};

class __declspec(uuid(DLL_UUID)) ExplorerCommandHandler final : public RuntimeClass<RuntimeClassFlags<ClassicCom | InhibitRoOriginateError>, IExplorerCommand> {
 public:
  // IExplorerCommand 接口实现：
  IFACEMETHODIMP GetTitle(IShellItemArray* items, PWSTR* name) {
    const wchar_t kDefaultTitle[] = L"通过 VS Code 打开";

    // 当在打包环境（MSIX）运行时，不读取旧版安装（MSI）写入的注册表状态。
    if (IsRunningPackaged()) {
      return SHStrDup(kDefaultTitle, name);
    }

    // 向后兼容：若注册表里存在 Title（通常来自旧 MSI 安装），则优先使用。
    const size_t kMaxStringLength = 1024;
    wchar_t value_w[kMaxStringLength] = {0};
    wchar_t expanded_value_w[kMaxStringLength] = {0};
    DWORD value_size_w = sizeof(value_w);

    #if defined(INSIDER)
        const wchar_t kTitleRegkey[] = L"Software\\Classes\\CodeInsidersModernExplorerMenu";
    #else
        const wchar_t kTitleRegkey[] = L"Software\\Classes\\CodeModernExplorerMenu";
    #endif

    HKEY subhkey = nullptr;
    LONG result = RegOpenKeyEx(HKEY_LOCAL_MACHINE, kTitleRegkey, 0, KEY_READ, &subhkey);
    if (result != ERROR_SUCCESS) {
      result = RegOpenKeyEx(HKEY_CURRENT_USER, kTitleRegkey, 0, KEY_READ, &subhkey);
    }

    if (result == ERROR_SUCCESS && subhkey != nullptr) {
      DWORD type = REG_EXPAND_SZ;
      LONG q = RegQueryValueEx(subhkey, L"Title", nullptr, &type,
                              reinterpret_cast<LPBYTE>(&value_w), &value_size_w);
      RegCloseKey(subhkey);

      if (q == ERROR_SUCCESS) {
        DWORD expanded = ExpandEnvironmentStrings(value_w, expanded_value_w, kMaxStringLength);
        if (expanded && expanded < kMaxStringLength) {
          return SHStrDup(expanded_value_w, name);
        }
      }
    }

    return SHStrDup(kDefaultTitle, name);
  }

  IFACEMETHODIMP GetIcon(IShellItemArray* items, PWSTR* icon) {
    std::filesystem::path module_path{ wil::GetModuleFileNameW<std::wstring>(wil::GetModuleInstanceHandle()) };
    const std::filesystem::path package_root = module_path.remove_filename();

    // 优先使用 VS Code 主程序 EXE 的图标资源（与其他应用一致，在 Win11 右键菜单里观感最好）。
    #if defined(INSIDER)
      const bool prefer_insiders = true;
    #else
      const bool prefer_insiders = false;
    #endif

    if (auto exe = FindVSCodeExePreferVariant(prefer_insiders)) {
      std::wstring exe_icon = exe->wstring();
      exe_icon.append(L",0");
      return SHStrDupW(exe_icon.c_str(), icon);
    }

    // 兜底：使用包内自带的 .ico，确保不依赖外部 VS Code 路径。
    std::filesystem::path icon_path = package_root / L"resources" / L"app" / L"resources" / L"win32" / L"code.ico";
    if (std::filesystem::exists(icon_path)) {
      return SHStrDupW(icon_path.c_str(), icon);
    }

    return E_FAIL;
  }

  IFACEMETHODIMP GetToolTip(IShellItemArray* items, PWSTR* infoTip) {
    *infoTip = nullptr;
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetCanonicalName(GUID* guidCommandName) {
    *guidCommandName = GUID_NULL;
    return S_OK;
  }

  IFACEMETHODIMP GetState(IShellItemArray* items, BOOL okToBeSlow, EXPCMDSTATE* cmdState) {
    *cmdState = AnyVariantAvailable() ? ECS_ENABLED : ECS_HIDDEN;
    return S_OK;
  }

  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) {
    *flags = ECF_HASSUBCOMMANDS;
    return S_OK;
  }

  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** enumCommands) {
    if (enumCommands == nullptr) {
      return E_POINTER;
    }
    *enumCommands = nullptr;

    std::vector<ComPtr<IExplorerCommand>> commands;
    if (IsVariantAvailable(VSCodeVariant::Stable)) {
      commands.push_back(Make<ExplorerSubCommand>(VSCodeVariant::Stable));
    }
    if (IsVariantAvailable(VSCodeVariant::Insiders)) {
      commands.push_back(Make<ExplorerSubCommand>(VSCodeVariant::Insiders));
    }

    if (commands.empty()) {
      return S_FALSE;
    }

    auto enumerator = Make<ExplorerCommandEnumerator>(commands);
    if (!enumerator) {
      return E_OUTOFMEMORY;
    }

    *enumCommands = enumerator.Detach();
    return S_OK;
  }

  IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx* bindCtx) {
    return S_OK;
  }
};

CoCreatableClass(ExplorerCommandHandler)
CoCreatableClassWrlCreatorMapInclude(ExplorerCommandHandler)

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID* ppv) {
  if (ppv == nullptr)
    return E_POINTER;
  *ppv = nullptr;
  return Module<ModuleType::InProc>::GetModule().GetClassObject(rclsid, riid, ppv);
}

STDAPI DllCanUnloadNow(void) {
  return Module<ModuleType::InProc>::GetModule().GetObjectCount() == 0 ? S_OK : S_FALSE;
}

STDAPI DllGetActivationFactory(HSTRING activatableClassId,
                               IActivationFactory** factory) {
  return Module<ModuleType::InProc>::GetModule().GetActivationFactory(activatableClassId, factory);
}
