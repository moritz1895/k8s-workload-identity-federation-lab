package ms.rohde.wifpoc.servicer;

import java.util.List;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/** Dummy order endpoints; each answer names the caller and the scopes it presented. */
@RestController
public class OrdersController {

    private static final Logger LOG = LogManager.getLogger(OrdersController.class);

    @GetMapping("/healthz")
    String health() {
        return "ok";
    }

    @GetMapping("/orders")
    OrderCall listOrders(@AuthenticationPrincipal Jwt jwt) {
        return answer(jwt, "GET /orders");
    }

    @PostMapping("/orders")
    OrderCall createOrder(@AuthenticationPrincipal Jwt jwt) {
        return answer(jwt, "POST /orders");
    }

    @DeleteMapping("/orders/{id}")
    OrderCall deleteOrder(@AuthenticationPrincipal Jwt jwt, @PathVariable String id) {
        return answer(jwt, "DELETE /orders/" + id);
    }

    private static OrderCall answer(Jwt jwt, String endpoint) {
        String scope = jwt.getClaimAsString("scope");
        List<String> scopes = scope == null ? List.of() : List.of(scope.split(" "));
        OrderCall call = new OrderCall(String.valueOf(jwt.getClaimAsString("azp")), scopes, endpoint);
        LOG.info("{} allowed for client {} with scopes {}", endpoint, call.clientId(), scopes);
        return call;
    }

    /** Response body: who called which endpoint with which scopes. */
    record OrderCall(String clientId, List<String> scopes, String endpoint) {
    }
}
