import { describe, it, expect } from 'vitest'
import * as Lauf from '../src/index.js'

describe('pakka', () => {
  it('eksporterer alt bolk 1 lover', () => {
    const forventet = [
      'Button', 'Input', 'Textarea', 'Select', 'Checkbox', 'Radio', 'Switch',
      'Field', 'Heading', 'Text', 'Icon', 'Badge', 'Card', 'Separator',
      'Table', 'Pagination', 'cn',
      'Modal', 'Dropdown', 'Tooltip', 'Popover', 'Tabs', 'Accordion',
      'Avatar', 'Callout', 'Breadcrumbs', 'Navbar', 'Sidebar', 'Skeleton',
      'Toaster', 'toast',
    ]
    for (const navn of forventet) expect(Lauf[navn], navn).toBeTruthy()
  })

  it('har de sammensatte delene', () => {
    expect(Lauf.Button.Group).toBeTruthy()
    expect(Lauf.Table.Head).toBeTruthy()
    expect(Lauf.Table.Body).toBeTruthy()
    expect(Lauf.Table.Row).toBeTruthy()
    expect(Lauf.Table.Header).toBeTruthy()
    expect(Lauf.Table.Cell).toBeTruthy()
    expect(Lauf.Dropdown.Item).toBeTruthy()
    expect(Lauf.Dropdown.Separator).toBeTruthy()
    expect(Lauf.Dropdown.Group).toBeTruthy()
    expect(Lauf.Tabs.Panel).toBeTruthy()
    expect(Lauf.Accordion.Item).toBeTruthy()
    expect(Lauf.Sidebar.Item).toBeTruthy()
  })
})
