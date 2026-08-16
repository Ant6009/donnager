{ config, pkgs, ... }:

{
  services.t2fanrd = {
    enable = true;

    config = {

      # ── Rear exhaust (main GPU cooling) ──────────────────────
      Fan1 = {
        low_temp = 40;        # start ramping at 40 °C
        high_temp = 65;       # full speed at 65 °C
        speed_curve = "exponential";
        # always_full_speed = false;
      };

      # ── Front intake(s) ──────────────────────────────────────
      Fan2 = {
        low_temp = 40;
        high_temp = 65;
        speed_curve = "exponential";
      };

      Fan3 = {
        low_temp = 40;
        high_temp = 65;
        speed_curve = "exponential";
      };
      Fan4 = {
        low_temp = 40;
        high_temp = 65;
        speed_curve = "exponential";
      };
    };
  };
}
