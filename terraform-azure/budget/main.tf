# A cost alarm, kept in its own Terraform root on purpose: `terraform destroy`
# of the demo (../) must not remove the thing that watches its cost.
#
# Honest limit: an Azure budget only SENDS EMAIL. It does not stop or delete
# anything, and cost data lags by hours. The real protection is
# `terraform destroy` the same day.
resource "azurerm_consumption_budget_subscription" "demo" {
  name            = "policyledger-demo"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.amount
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 25
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }

  lifecycle {
    # timestamp() changes every run; the start date only matters at creation.
    ignore_changes = [time_period]
  }
}
