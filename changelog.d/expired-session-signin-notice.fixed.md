- **Expired sessions keep cached telemetry visible behind the sign-in notice.** Re-authentication
  prompts no longer fall straight into `WelcomeSignInView` when a cached vehicle snapshot exists on
  disk, keeping the dashboard readable under the dismissible `signInNotice` banner while uncached
  launches continue showing the onboarding sign-in view.
