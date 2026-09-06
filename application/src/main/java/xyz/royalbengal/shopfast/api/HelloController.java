package xyz.royalbengal.shopfast.api;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Public API surface of ShopFast.
 *
 * The release metadata returned here is what makes a Blue/Green or Canary
 * rollout observable from outside the cluster: during a canary some fraction
 * of responses carry the new colour and version, and the counter is labelled
 * so the same split is visible in VictoriaMetrics and Grafana.
 */
@RestController
@RequestMapping("/api")
public class HelloController {

    private final String releaseColor;
    private final String appVersion;
    private final String podName;
    private final Counter helloCounter;

    public HelloController(
            @Value("${shopfast.release-color:blue}") String releaseColor,
            @Value("${shopfast.version:unknown}") String appVersion,
            @Value("${HOSTNAME:local}") String podName,
            MeterRegistry registry) {
        this.releaseColor = releaseColor;
        this.appVersion = appVersion;
        this.podName = podName;
        this.helloCounter = Counter.builder("shopfast_hello_requests_total")
                .description("Total number of /api/hello requests served")
                .tag("release_color", releaseColor)
                .tag("version", appVersion)
                .register(registry);
    }

    @GetMapping("/hello")
    public Map<String, Object> hello() {
        helloCounter.increment();

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("message", "Hello from ShopFast");
        body.put("service", "shopfast");
        body.put("version", appVersion);
        body.put("releaseColor", releaseColor);
        body.put("pod", podName);
        body.put("timestamp", Instant.now().toString());
        return body;
    }

    @GetMapping("/info")
    public Map<String, Object> info() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", "shopfast");
        body.put("version", appVersion);
        body.put("releaseColor", releaseColor);
        body.put("pod", podName);
        body.put("java", System.getProperty("java.version"));
        return body;
    }
}
