package xyz.royalbengal.shopfast;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.ClassPathResource;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.forwardedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest(properties = {
        "shopfast.release-color=green",
        "shopfast.version=test-sha"
})
@AutoConfigureMockMvc
class ShopFastApplicationTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void contextLoads() {
        // Fails the build if any bean wiring or config binding is broken.
    }

    @Test
    void helloEndpointReturnsReleaseMetadata() throws Exception {
        mockMvc.perform(get("/api/hello"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service").value("shopfast"))
                .andExpect(jsonPath("$.message").value("Hello from ShopFast"))
                .andExpect(jsonPath("$.releaseColor").value("green"))
                .andExpect(jsonPath("$.version").value("test-sha"));
    }

    @Test
    void infoEndpointReportsRelease() throws Exception {
        mockMvc.perform(get("/api/info"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service").value("shopfast"))
                .andExpect(jsonPath("$.releaseColor").value("green"))
                .andExpect(jsonPath("$.version").value("test-sha"));
    }

    @Test
    void healthEndpointIsUp() throws Exception {
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void readinessProbeIsExposed() throws Exception {
        mockMvc.perform(get("/actuator/health/readiness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void prometheusEndpointExposesCustomCounter() throws Exception {
        mockMvc.perform(get("/api/hello")).andExpect(status().isOk());

        mockMvc.perform(get("/actuator/prometheus"))
                .andExpect(status().isOk())
                .andExpect(content().string(
                        org.hamcrest.Matchers.containsString("shopfast_hello_requests_total")));
    }

    /**
     * The root path must serve the static landing page.
     *
     * MockMvc does NOT execute the servlet forward that Spring Boot's welcome-page
     * handler produces, so the mock response body is empty by design. Asserting on
     * rendered content here would test the mock, not the app. The correct contract
     * to assert is: 200 plus a forward to index.html.
     *
     * The page's actual content is verified separately below, and the fully
     * rendered page is proven end-to-end by the live HTTPS probe of
     * https://shopfast.<domain>/ in gitops/bootstrap/verify.sh.
     */
    @Test
    void rootForwardsToTheLandingPage() throws Exception {
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(forwardedUrl("index.html"));
    }

    @Test
    void landingPageContainsTheApplicationUi() throws Exception {
        String page = new ClassPathResource("static/index.html")
                .getContentAsString(StandardCharsets.UTF_8);

        assertThat(page)
                .contains("ShopFast")
                .contains("/api/hello")
                .contains("/actuator/prometheus");
    }
}
