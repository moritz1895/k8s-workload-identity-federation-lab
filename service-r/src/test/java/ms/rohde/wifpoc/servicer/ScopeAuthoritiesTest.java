package ms.rohde.wifpoc.servicer;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;

class ScopeAuthoritiesTest {

    @Test
    void convert_givenScopeClaim_thenMapsToScopeAuthorities() {
        Jwt jwt = Jwt.withTokenValue("token")
                .header("alg", "RS256")
                .claim("azp", "workload-a")
                .claim("scope", "r:orders:read r:orders:write")
                .issuedAt(Instant.now())
                .expiresAt(Instant.now().plusSeconds(300))
                .build();

        AbstractAuthenticationToken authentication = SecurityConfig.scopeAuthenticationConverter().convert(jwt);

        assertThat(authentication).isNotNull();
        assertThat(authentication.getName()).isEqualTo("workload-a");
        assertThat(authentication.getAuthorities())
                .extracting(GrantedAuthority::getAuthority)
                .filteredOn(authority -> authority.startsWith("SCOPE_"))
                .containsExactlyInAnyOrder("SCOPE_r:orders:read", "SCOPE_r:orders:write");
    }
}
