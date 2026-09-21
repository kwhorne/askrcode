<script>
  import { Tabs } from '../../src/index.js'
  import { User, Bell, ArrowRight } from '../../src/icons/micro/index.js'

  let {
    value = $bindable('profile'),
    variant = 'underline',
    size = 'base',
    scrollable = false,
    findable = false,
  } = $props()

  const tabs = [
    { value: 'profile', label: 'Profile', icon: User },
    { value: 'orders', label: 'Orders', icon: Bell, badge: 12 },
    { value: 'more', label: 'More', iconTrailing: ArrowRight },
    { value: 'billing', label: 'Billing', disabled: true },
  ]
</script>

<Tabs bind:value {tabs} {variant} {size} {scrollable}>
  <Tabs.Panel value="profile" {findable}>Your profile lives here</Tabs.Panel>
  <Tabs.Panel value="orders" {findable}>A needle in the orders panel</Tabs.Panel>
  <Tabs.Panel value="more" {findable}>More</Tabs.Panel>
  <Tabs.Panel value="billing" {findable}>Billing</Tabs.Panel>
</Tabs>
