import android.location.Location;
import android.location.LocationRequest;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.SystemClock;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/** Reads the system cache by default; only --refresh registers a bounded request. */
public final class HitohiraLoc {
    private static final String PACKAGE = "com.android.shell";
    private static final String CALLBACK = "android.location.ILocationCallback";
    private static final Class<?> MANAGER;
    static {
        try { MANAGER = Class.forName("android.location.ILocationManager"); }
        catch (Exception e) { throw new ExceptionInInitializerError(e); }
    }

    private static Object call(Object target, String name, Class<?>[] types, Object... args)
            throws Exception {
        return target.getClass().getMethod(name, types).invoke(target, args);
    }

    private static final class Callback extends Binder {
        final java.util.concurrent.BlockingQueue<Location> fixes;
        Callback(java.util.concurrent.BlockingQueue<Location> fixes) { this.fixes = fixes; }
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws RemoteException {
            if (code == IBinder.FIRST_CALL_TRANSACTION) {
                data.enforceInterface(CALLBACK);
                Location location = data.readTypedObject(Location.CREATOR);
                // Some OEM providers deliver an old fix to a current-location request.
                if (location != null && !location.isMock()
                        && SystemClock.elapsedRealtimeNanos() - location.getElapsedRealtimeNanos()
                                <= TimeUnit.SECONDS.toNanos(30)) fixes.offer(location);
                return true;
            }
            return super.onTransact(code, data, reply, flags);
        }
    }

    private static Location refresh(Object service) throws Exception {
        Class<?> cbClass = Class.forName(CALLBACK);
        Method method = MANAGER.getMethod("getCurrentLocation", String.class,
                LocationRequest.class, cbClass, String.class, String.class, String.class);
        java.util.concurrent.BlockingQueue<Location> fixes =
                new java.util.concurrent.LinkedBlockingQueue<>();
        java.util.List<Object> cancellations = new java.util.ArrayList<>();
        long deadline = SystemClock.elapsedRealtime() + 15000;
        try {
            for (String provider : new String[]{"network", "fused"}) {
                Callback cb = new Callback(fixes);
                Object callback = Proxy.newProxyInstance(cbClass.getClassLoader(),
                        new Class<?>[]{cbClass}, (proxy, m, args) -> {
                            if (m.getName().equals("asBinder")) return cb;
                            throw new UnsupportedOperationException(m.getName());
                        });
                LocationRequest request = new LocationRequest.Builder(0)
                        .setQuality(LocationRequest.QUALITY_BALANCED_POWER_ACCURACY)
                        .setDurationMillis(15000).setMaxUpdates(1).build();
                try {
                    Object cancellation = method.invoke(service, provider, request, callback,
                            PACKAGE, null, "hitohira-loc-" + provider);
                    if (cancellation != null) cancellations.add(cancellation);
                } catch (java.lang.reflect.InvocationTargetException e) {
                    if (!(e.getCause() instanceof IllegalArgumentException)) throw e;
                    // A provider may be absent on an OEM device.
                }
            }
            Location fix = fixes.poll(Math.max(0, deadline - SystemClock.elapsedRealtime()),
                    TimeUnit.MILLISECONDS);
            if (fix == null)
                throw new IllegalStateException("No fresh network/fused fix within 15 seconds");
            return fix;
        } finally {
            for (Object cancellation : cancellations)
                Class.forName("android.os.ICancellationSignal").getMethod("cancel")
                        .invoke(cancellation);
        }
    }

    public static void main(String[] args) {
        try {
            boolean refresh = args.length == 1 && args[0].equals("--refresh");
            if (args.length > 0 && !refresh)
                throw new IllegalArgumentException("Usage: hitohira-loc [--refresh]");
            Object binder = Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String.class).invoke(null, "location");
            Object service = Class.forName("android.location.ILocationManager$Stub")
                    .getMethod("asInterface", IBinder.class).invoke(null, binder);
            Location best = null;
            if (refresh) {
                best = refresh(service);
            } else {
                Object builder = Class.forName("android.location.LastLocationRequest$Builder")
                        .getConstructor().newInstance();
                // Cached reads note access, but do not start a running location operation.
                Object request = call(builder, "build", new Class<?>[]{});
                Method last = MANAGER.getMethod("getLastLocation", String.class,
                        request.getClass(), String.class, String.class);
                for (String provider : new String[]{"fused", "network", "gps", "passive"}) {
                    Location location;
                    try {
                        location = (Location) last.invoke(service, provider, request, PACKAGE, null);
                    } catch (java.lang.reflect.InvocationTargetException e) {
                        if (e.getCause() instanceof IllegalArgumentException) continue;
                        throw e;
                    }
                    if (location != null && !location.isMock()
                            && (best == null || location.getElapsedRealtimeNanos()
                                    > best.getElapsedRealtimeNanos())) best = location;
                }
            }
            if (best == null) throw new IllegalStateException("No cached location");
            JSONObject result = new JSONObject();
            result.put("provider", best.getProvider());
            result.put("lat", best.getLatitude());
            result.put("lon", best.getLongitude());
            result.put("accuracy_m", best.getAccuracy());
            result.put("elapsed_ms", best.getElapsedRealtimeNanos() / 1000000);
            result.put("age_s", Math.max(0,
                    (SystemClock.elapsedRealtimeNanos() - best.getElapsedRealtimeNanos()) / 1e9));
            System.out.println(result);
            System.exit(0);
        } catch (Throwable e) {
            while (e.getCause() != null) e = e.getCause();
            System.err.println("hitohira-loc: " + e);
            System.exit(1);
        }
    }
}
