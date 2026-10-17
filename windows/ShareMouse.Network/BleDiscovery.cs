using System.Collections.Concurrent;
using ShareMouse.Core;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using Windows.Foundation;

namespace ShareMouse.Network;

public sealed class BleDiscovery : IDisposable
{
    public static readonly Guid ServiceId = Guid.Parse("436CA682-AC49-45F2-95D4-D37B41130558");
    private static readonly Guid receiveId = Guid.Parse("436CA682-AC49-45F2-95D4-D37B4113055B");
    private static readonly Guid transmitId = Guid.Parse("436CA682-AC49-45F2-95D4-D37B4113055C");
    private BluetoothLEAdvertisementWatcher? watcher;
    private GattServiceProvider? provider;
    private GattLocalCharacteristic? serverTx;
    private GattLocalCharacteristic? serverRx;
    private readonly ConcurrentDictionary<string, BleByteBridge> incoming = new();
    private readonly ConcurrentDictionary<ulong, BleByteBridge> outgoing = new();
    private readonly ConcurrentDictionary<ulong, BluetoothLEDevice> devices = new();
    private readonly ConcurrentDictionary<ulong, byte> opening = new();
    private readonly SemaphoreSlim serverReceiveGate = new(1, 1);
    private readonly int serverPort;
    private bool disposed, started;
    private int manualScanRound;
    private bool realtimeInput;
    private long activeScanDeadline;
    private readonly object scanGate = new();
    public void SetRealtimeInputEnabled(bool enabled)
    {
        lock (scanGate)
        {
            realtimeInput = enabled;
            RefreshScanning();
        }
    }
    private void RefreshScanning()
    {
        lock (scanGate)
        {
            if (disposed || watcher is null)
                return;
            var pause = realtimeInput && (!outgoing.IsEmpty || !incoming.IsEmpty) && Environment.TickCount64 >= activeScanDeadline;
            if (pause && watcher.Status == BluetoothLEAdvertisementWatcherStatus.Started)
            {
                watcher.Stop();
                Status?.Invoke("BLEDiscoveryPausedForInput");
            }
            else if (!pause && watcher.Status is BluetoothLEAdvertisementWatcherStatus.Created or BluetoothLEAdvertisementWatcherStatus.Stopped or BluetoothLEAdvertisementWatcherStatus.Aborted)
            {
                watcher.Start();
                Status?.Invoke("BLEBackgroundDiscovery");
            }
        }
    }

    public event Action<string>? Status;
    public event Action<string, string>? Found;
    public BleDiscovery(int serverPort = 49165)
    {
        this.serverPort = serverPort;
    }

    private volatile bool available = true;
    private string pairCode = "";
    public void UpdatePairCode(string code)
    {
        pairCode = code;
        Advertise();
    }
    private readonly object advertiseGate = new();
    private bool advertising;
    private void Advertise()
    {
        lock (advertiseGate)
        {
            if (disposed || !available || provider is null || serverTx is null || serverRx is null)
                return;
            try
            {
                StopAdvertising();
                // Keep the mandatory service UUID advertisement small. Pair code is checked in the TLS hello.
                provider.StartAdvertising(new GattServiceProviderAdvertisingParameters { IsDiscoverable = true, IsConnectable = true });
                advertising = true;
            }
            catch (Exception ex) { Status?.Invoke($"BLEAdvertiseUnavailable error={ex.GetType().Name} code={ex.HResult} detail={ex.Message}"); }
        }
    }
    private void StopAdvertising()
    {
        lock (advertiseGate)
        {
            if (advertising)
            {
                provider?.StopAdvertising();
                advertising = false;
            }
        }
    }
    public void SetAvailable(bool enabled)
    {
        available = enabled;
        if (enabled)
            Advertise();
        else
            StopAdvertising();
    }
    public async Task StartAsync()
    {
        if (started || disposed)
            return;
        started = true;
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter is null)
            {
                Status?.Invoke("BLEUnavailable adapter=missing");
                return;
            }
            if (adapter.IsCentralRoleSupported)
            {
                watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
                watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(ServiceId);
                watcher.Received += (_, args) =>
                {
                    var name = args.Advertisement.LocalName;
                    foreach (var section in args.Advertisement.DataSections.Where(s => s.DataType == 0x21))
                    {
                        var bytes = section.Data.ToArray();
                        if (bytes.Length == 22 && new Guid(bytes.AsSpan(0, 16)) == ServiceId)
                            name = "SM" + System.Text.Encoding.UTF8.GetString(bytes, 16, 6);
                    }
                    Found?.Invoke(args.BluetoothAddress.ToString("X12"), string.IsNullOrWhiteSpace(name) ? "ShareMouse 设备" : name);
                };
                watcher.Stopped += (_, args) => { Status?.Invoke("BLEScanStopped error=" + args.Error); RefreshScanning(); };
                watcher.Start();
                Status?.Invoke("BLEScanReady");
            }
            else
                Status?.Invoke("BLEScanUnavailable");
            if (adapter.IsPeripheralRoleSupported)
            {
                var result = await GattServiceProvider.CreateAsync(ServiceId);
                if (result.Error != BluetoothError.Success)
                    throw new IOException("GATT provider unavailable.");
                provider = result.ServiceProvider;
                var rx = await provider.Service.CreateCharacteristicAsync(receiveId, new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Write | GattCharacteristicProperties.WriteWithoutResponse,
                    WriteProtectionLevel = GattProtectionLevel.Plain
                });
                var tx = await provider.Service.CreateCharacteristicAsync(transmitId, new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Notify,
                    ReadProtectionLevel = GattProtectionLevel.Plain
                });
                if (rx.Error != BluetoothError.Success || tx.Error != BluetoothError.Success)
                    throw new IOException("GATT characteristics unavailable.");
                serverTx = tx.Characteristic;
                serverRx = rx.Characteristic;
                serverTx.SubscribedClientsChanged += (_, _) => SubscribersChanged();
                serverRx.WriteRequested += async (_, args) =>
                {
                    var deferral = args.GetDeferral();
                    await serverReceiveGate.WaitAsync();
                    try
                    {
                        var request = await args.GetRequestAsync();
                        if (request is null)
                            return;
                        if (!incoming.TryGetValue(args.Session.DeviceId.Id, out var bridge) || request.Offset != 0)
                        {
                            if (request.Option == GattWriteOption.WriteWithResponse)
                                request.RespondWithProtocolError(0x0E);
                            return;
                        }
                        await bridge.ReceiveFragmentAsync(request.Value.ToArray());
                        if (request.Option == GattWriteOption.WriteWithResponse)
                            request.Respond();
                    }
                    catch { Status?.Invoke("BLEWriteFailed"); }
                    finally { serverReceiveGate.Release(); deferral.Complete(); }
                };
                provider.AdvertisementStatusChanged += (_, args) => Status?.Invoke((args.Status == GattServiceProviderAdvertisementStatus.Aborted ? "BLEAdvertiseUnavailable" : "BLEAdvertise") + " state=" + args.Status + " error=" + args.Error);
                Advertise();
            }
            else
                Status?.Invoke("BLEAdvertiseUnavailable peripheralRole=false");
        }
        catch (Exception ex) { Status?.Invoke($"BLEUnavailable error={ex.GetType().Name} code={ex.HResult} detail={ex.Message}"); }
    }
    private sealed record PeripheralTiming(BleByteBridge Owner, BluetoothLEDevice Device, BluetoothLEPreferredConnectionParametersRequest Request);
    private readonly ConcurrentDictionary<string, PeripheralTiming> peripheralTiming = new();
    private readonly SynchronizationContext? deviceContext = SynchronizationContext.Current;
    private Task<BluetoothLEDevice?> GetIncomingDevice(string id)
    {
        if (deviceContext is null)
            return BluetoothLEDevice.FromIdAsync(id).AsTask();
        var ready = new TaskCompletionSource<BluetoothLEDevice?>(TaskCreationOptions.RunContinuationsAsynchronously);
        // Only initial device consent uses the UI context. Transfer loops never do.
        deviceContext.Post(async _ => { try { ready.TrySetResult(await BluetoothLEDevice.FromIdAsync(id)); } catch (Exception e) { ready.TrySetException(e); } }, null);
        return ready.Task;
    }
    private async Task TuneIncoming(string id, BleByteBridge owner)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
            return;
        BluetoothLEDevice? device = null;
        BluetoothLEPreferredConnectionParametersRequest? request = null;
        try
        {
            device = await GetIncomingDevice(id).ConfigureAwait(false);
            if (device is null)
                return;
            ReportConnection(device, "peripheral-before-request");
            // WinRT has no GattServiceProvider parameter-update API; the device request is advisory.
            request = device.RequestPreferredConnectionParameters(BluetoothLEPreferredConnectionParameters.ThroughputOptimized);
            Status?.Invoke("BLEParameterRequest role=peripheral status=" + request.Status);
            if (disposed || !incoming.TryGetValue(id, out var current) || !ReferenceEquals(current, owner))
                return;
            var timing = new PeripheralTiming(owner, device, request);
            if (!peripheralTiming.TryAdd(id, timing))
                return;
            device = null;
            request = null;
            await Task.Delay(2000).ConfigureAwait(false);
            if (peripheralTiming.TryGetValue(id, out var held) && ReferenceEquals(held.Owner, owner))
            {
                Status?.Invoke("BLEParameterRequest role=peripheral-settled status=" + held.Request.Status);
                ReportConnection(held.Device, "peripheral-settled");
            }
        }
        catch (Exception e) { Status?.Invoke($"BLEPeripheralParameterRequestUnavailable error={e.GetType().Name} code={e.HResult}"); }
        finally { request?.Dispose(); device?.Dispose(); }
    }
    private void ReleasePeripheralTiming(string id, BleByteBridge? owner)
    {
        if (peripheralTiming.TryGetValue(id, out var held) && ReferenceEquals(held.Owner, owner) && ((ICollection<KeyValuePair<string, PeripheralTiming>>)peripheralTiming).Remove(new(id, held)))
        {
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
                held.Request.Dispose();
            held.Device.Dispose();
        }
    }
    private void SubscribersChanged()
    {
        if (disposed || serverTx is null)
            return;
        var present = serverTx.SubscribedClients.Select(s => s.Session.DeviceId.Id).ToHashSet();
        foreach (var entry in incoming)
            if (!present.Contains(entry.Key) && incoming.TryRemove(entry.Key, out var old))
                old.Dispose();
        foreach (var subscriber in serverTx.SubscribedClients)
        {
            var id = subscriber.Session.DeviceId.Id;
            if (incoming.ContainsKey(id))
                continue;
            Status?.Invoke($"BLELinkParameters role=peripheral mtu={subscriber.Session.MaxPduSize}");
            subscriber.Session.MaxPduSizeChanged += (session, _) => Status?.Invoke($"BLELinkParameters role=peripheral mtu={session.MaxPduSize}");
            var framer = new BleStreamFraming();
            BleByteBridge? bridge = null;
            bridge = new BleByteBridge(async bytes =>
            {
                var maximum = Math.Clamp(subscriber.Session.MaxPduSize - 3, 20, 512) - 12;
                for (var offset = 0; offset < bytes.Length; offset += maximum)
                {
                    var packet = bytes.AsSpan(offset, Math.Min(maximum, bytes.Length - offset)).ToArray();
                    var result = await serverTx.NotifyValueAsync(framer.Encode(packet).AsBuffer(), subscriber).AsTask().ConfigureAwait(false);
                    if (result.Status != GattCommunicationStatus.Success)
                        throw new IOException("BLE notification failed.");
                }
            }, () => { if (bridge is not null) ((ICollection<KeyValuePair<string, BleByteBridge>>)incoming).Remove(new(id, bridge)); ReleasePeripheralTiming(id, bridge); RefreshScanning(); }, value => Status?.Invoke(value));
            if (incoming.TryAdd(id, bridge))
            {
                RefreshScanning();
                _ = ConnectIncoming(bridge);
                _ = TuneIncoming(id, bridge);
            }
            else
                bridge.Dispose();
        }
    }
    private async Task ConnectIncoming(BleByteBridge bridge)
    {
        try
        {
            await bridge.ConnectAsync(serverPort).ConfigureAwait(false);
        }
        catch { bridge.Dispose(); }
    }

    public async Task<int> ConnectAsync(string locator)
    {
        if (disposed)
            throw new ObjectDisposedException(nameof(BleDiscovery));
        var address = Convert.ToUInt64(locator, 16);
        if (!opening.TryAdd(address, 0))
            throw new IOException("BLE connection already in progress.");
        try
        {
            return await ConnectCore(address);
        }
        finally { opening.TryRemove(address, out _); }
    }
    private void ReportConnection(BluetoothLEDevice device, string role)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || !Windows.Foundation.Metadata.ApiInformation.IsMethodPresent("Windows.Devices.Bluetooth.BluetoothLEDevice", "GetConnectionParameters"))
            return;
        try
        {
            var actual = device.GetConnectionParameters();
            var requested = BluetoothLEPreferredConnectionParameters.ThroughputOptimized;
            Status?.Invoke($"BLEConnectionTiming role={role} actualIntervalMs={actual.ConnectionInterval * 1.25:F2} peripheralLatency={actual.ConnectionLatency} supervisionMs={actual.LinkTimeout * 10} requestedMinMs={requested.MinConnectionInterval * 1.25:F2} requestedMaxMs={requested.MaxConnectionInterval * 1.25:F2}");
        }
        catch (Exception error) { Status?.Invoke("BLEConnectionTimingUnavailable error=" + error.GetType().Name); }
    }
    private async Task<int> ConnectCore(ulong address)
    {
        if (outgoing.ContainsKey(address))
            throw new IOException("BLE endpoint is already connected.");
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address) ?? throw new IOException("BLE device unavailable.");
        GattDeviceService? service = null;
        BleByteBridge? bridge = null;
        try
        {
            var services = await device.GetGattServicesForUuidAsync(ServiceId, BluetoothCacheMode.Uncached);
            service = services.Services.FirstOrDefault() ?? throw new IOException("BLE service unavailable.");
            var characteristics = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
            var rx = characteristics.Characteristics.FirstOrDefault(c => c.Uuid == receiveId) ?? throw new IOException("BLE RX unavailable.");
            var tx = characteristics.Characteristics.FirstOrDefault(c => c.Uuid == transmitId) ?? throw new IOException("BLE TX unavailable.");
            service.Session.MaintainConnection = true;
            var activeService = service;
            BluetoothLEPreferredConnectionParametersRequest? parameters = null;
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) && Windows.Foundation.Metadata.ApiInformation.IsMethodPresent("Windows.Devices.Bluetooth.BluetoothLEDevice", "RequestPreferredConnectionParameters"))
            {
                parameters = device.RequestPreferredConnectionParameters(BluetoothLEPreferredConnectionParameters.ThroughputOptimized);
                Status?.Invoke("BLEParameterRequest role=central status=" + parameters.Status);
            }
            var writeOption = rx.CharacteristicProperties.HasFlag(GattCharacteristicProperties.WriteWithoutResponse) ? GattWriteOption.WriteWithoutResponse : GattWriteOption.WriteWithResponse;
            ReportConnection(device, "central");
            Status?.Invoke($"BLELinkParameters role=central mtu={service.Session.MaxPduSize} writeOption={writeOption}");
            service.Session.MaxPduSizeChanged += (session, _) => Status?.Invoke($"BLELinkParameters role=central mtu={session.MaxPduSize}");
            var framer = new BleStreamFraming();
            var notificationReference = new WeakReference<GattCharacteristic>(tx);
            TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>? notificationHandler = null;
            TypedEventHandler<BluetoothLEDevice, object>? disconnectedHandler = null;
            bridge = new BleByteBridge(async bytes =>
            {
                var maximum = Math.Clamp(activeService.Session.MaxPduSize - 3, 20, 512) - 12;
                for (var offset = 0; offset < bytes.Length; offset += maximum)
                {
                    var packet = bytes.AsSpan(offset, Math.Min(maximum, bytes.Length - offset)).ToArray();
                    var status = await rx.WriteValueAsync(framer.Encode(packet).AsBuffer(), writeOption).AsTask().ConfigureAwait(false);
                    if (status != GattCommunicationStatus.Success)
                        throw new IOException("BLE write failed.");
                }
            }, () =>
            {
                // Keep the WinRT event source alive for the whole bridge lifetime.
                // Registering an event alone does not root its managed wrapper.
                if (notificationHandler is not null)
                    tx.ValueChanged -= notificationHandler;
                if (disconnectedHandler is not null)
                    device.ConnectionStatusChanged -= disconnectedHandler;
                if (bridge is not null)
                    ((ICollection<KeyValuePair<ulong, BleByteBridge>>)outgoing).Remove(new(address, bridge));
                devices.TryRemove(address, out _);
                RefreshScanning();
                if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
                    parameters?.Dispose();
                activeService.Session.MaintainConnection = false;
                activeService.Session.Dispose();
                activeService.Dispose();
                device.Dispose();
            }, value => Status?.Invoke(value));
            if (disposed)
            {
                bridge.Dispose();
                throw new ObjectDisposedException(nameof(BleDiscovery));
            }
            outgoing[address] = bridge;
            devices[address] = device;
            RefreshScanning();
            // A previous TLS bridge can close while the OS retains its GATT subscription.
            // Force a fresh subscription edge so the peer creates a new byte stream.
            var reset = await tx.WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue.None).AsTask().WaitAsync(TimeSpan.FromSeconds(3));
            if (reset != GattCommunicationStatus.Success)
            {
                bridge.Dispose();
                throw new IOException("BLE subscription reset failed.");
            }
            notificationHandler = async (_, args) => { try { await bridge.ReceiveFragmentAsync(args.CharacteristicValue.ToArray()); } catch { bridge.Dispose(); } };
            disconnectedHandler = (_, _) => { if (device.ConnectionStatus == BluetoothConnectionStatus.Disconnected) bridge.Dispose(); };
            tx.ValueChanged += notificationHandler;
            device.ConnectionStatusChanged += disconnectedHandler;
            _ = Task.Run(async () => { await Task.Delay(2000); if (!disposed && outgoing.TryGetValue(address, out var current) && ReferenceEquals(current, bridge)) ReportConnection(device, "central-settled"); });
            var configured = await tx.WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (configured != GattCommunicationStatus.Success)
            {
                bridge.Dispose();
                throw new IOException("BLE subscription failed.");
            }
#if DEBUG
            if (Environment.GetCommandLineArgs().Contains("--ble-lifetime-check"))
                _ = Task.Run(async () =>
                {
                    await Task.Delay(10000);
                    GC.Collect();
                    GC.WaitForPendingFinalizers();
                    GC.Collect();
                    Status?.Invoke("BLELifetimeCheck forcedCollection=true notificationAlive=" + notificationReference.TryGetTarget(out _));
                });
#endif
            return bridge.Listen();
        }
        catch (Exception error)
        {
            Status?.Invoke("BLEConnectFailed error=" + error.GetType().Name + " detail=" + error.Message);
            // A CCCD timeout must release the registered bridge as well as GATT.
            // Otherwise outgoing blocks every subsequent reconnect attempt.
            if (bridge is not null)
                bridge.Dispose();
            else
            {
                service?.Dispose();
                device.Dispose();
            }
            throw;
        }
    }
    public async Task TryDiscoveryAsync()
    {
        await StartAsync();
        if (watcher is null || disposed)
            return;
        activeScanDeadline = Environment.TickCount64 + 60000;
        var round = ++manualScanRound;
        watcher.Stop();
        watcher.ScanningMode = BluetoothLEScanningMode.Active;
        watcher.Start();
        Status?.Invoke("BLEActiveDiscovery");
        await Task.Delay(TimeSpan.FromMinutes(1));
        if (disposed || manualScanRound != round)
            return;
        activeScanDeadline = 0;
        watcher.Stop();
        watcher.ScanningMode = BluetoothLEScanningMode.Active;
        RefreshScanning();
    }
    public void Dispose()
    {
        disposed = true;
        watcher?.Stop();
        StopAdvertising();
        foreach (var bridge in outgoing.Values)
            bridge.Dispose();
        foreach (var bridge in incoming.Values)
            bridge.Dispose();
    }
}
