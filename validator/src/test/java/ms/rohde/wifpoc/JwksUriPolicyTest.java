package ms.rohde.wifpoc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

class JwksUriPolicyTest {

    private static final String ISSUER = "https://issuer.wif.local";

    @Test
    void jwksUrl_givenJwksUriOnTheIssuerOrigin_thenReturnsIt() throws Exception {
        assertThat(JwksUriPolicy.jwksUrl(ISSUER, "https://issuer.wif.local/openid/v1/jwks"))
                .hasToString("https://issuer.wif.local/openid/v1/jwks");
    }

    @Test
    void jwksUrl_givenJwksUriOnAnotherHost_thenRejected() {
        assertThatThrownBy(() -> JwksUriPolicy.jwksUrl(ISSUER, "https://service-r.wif.local/openid/v1/jwks"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("origin");
    }

    @Test
    void jwksUrl_givenJwksUriOnAnotherPort_thenRejected() {
        assertThatThrownBy(() -> JwksUriPolicy.jwksUrl(ISSUER, "https://issuer.wif.local:8443/openid/v1/jwks"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void jwksUrl_givenExplicitDefaultPort_thenAccepted() throws Exception {
        assertThat(JwksUriPolicy.jwksUrl(ISSUER, "https://issuer.wif.local:443/openid/v1/jwks"))
                .hasToString("https://issuer.wif.local:443/openid/v1/jwks");
    }

    @Test
    void jwksUrl_givenPlainHttp_thenRejected() {
        assertThatThrownBy(() -> JwksUriPolicy.jwksUrl(ISSUER, "http://issuer.wif.local/openid/v1/jwks"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void jwksUrl_givenUserInfoTrick_thenRejected() {
        assertThatThrownBy(() -> JwksUriPolicy.jwksUrl(ISSUER, "https://issuer.wif.local@evil.example/jwks"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void jwksUrl_givenHostDifferingOnlyInCase_thenAccepted() throws Exception {
        assertThat(JwksUriPolicy.jwksUrl(ISSUER, "https://ISSUER.wif.local/openid/v1/jwks")).isNotNull();
    }
}
