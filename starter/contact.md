---
title: Contact
subtitle: Get in touch.
form: contact
register:
  - sitemap.xml
---

<style>
  .lazysite-form {
    max-width: min(480px, 100%);
    margin: 1rem 0;
    box-sizing: border-box;
  }
  .lazysite-form .form-field {
    display: grid;
    grid-template-columns: 7rem 1fr;
    gap: 0.6rem 0.75rem;
    align-items: start;
    margin-bottom: 0.6rem;
  }
  .lazysite-form .form-field label {
    text-align: right;
    padding-top: 0.45rem;
  }
  .lazysite-form input[type="text"],
  .lazysite-form input[type="email"],
  .lazysite-form input[type="tel"],
  .lazysite-form input[type="number"],
  .lazysite-form textarea,
  .lazysite-form select {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    padding: 0.4rem 0.55rem;
    border: 1px solid #ccc;
    border-radius: 3px;
    font: inherit;
  }
  .lazysite-form textarea {
    min-height: 6rem;
    resize: vertical;
  }
  .lazysite-form input:focus,
  .lazysite-form textarea:focus,
  .lazysite-form select:focus {
    outline: 2px solid #0056b3;
    outline-offset: 0;
  }
  .lazysite-form .required {
    color: #888;
    font-weight: normal;
  }
  .lazysite-form .form-field.form-submit > button {
    grid-column: 2;
    padding: 0.45rem 1.25rem;
    font: inherit;
    cursor: pointer;
    border: 1px solid #0056b3;
    background: #0056b3;
    color: #fff;
    border-radius: 3px;
  }
  .lazysite-form .form-field.form-submit > button:hover {
    background: #003d80;
    border-color: #003d80;
  }
  .lazysite-form .form-status {
    margin-top: 0.5rem;
    font-size: 0.9rem;
    color: #666;
  }
</style>

::: form
name    | Your name       | required max:200
email   | Email address   | required email max:254
phone   | Phone number    | optional max:30
message | Your message    | required textarea max:5000
submit  | Send message
:::
