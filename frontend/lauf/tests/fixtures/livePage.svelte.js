// Inertia 3's page is a $state object; the mock has to be one too, or the
// component's $derived would never see a navigation.
export const page = $state({ props: {} })
